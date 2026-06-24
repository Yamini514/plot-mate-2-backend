class App::Services::Approvals < App::Services::Base
  # The venture's request/approval queue. Reviews requests raised by other flows
  # (owner verification, plot claim, ownership transfer, document verification),
  # records a step-by-step timeline, and applies the type-specific side effect on
  # approval. Tenant-scoped to the admin's own venture.
  def model = ApprovalRequest

  def list
    ds = scoped.order(Sequel.desc(:created_at))
    ds = ds.where(status: qs[:status])           if qs[:status].present? && qs[:status] != 'all'
    ds = ds.where(request_type: qs[:request_type]) if qs[:request_type].present?
    return_success(ds.all.map { |a| a.as_pos }, counts: counts_by_status)
  end

  def get = return_success(item.as_pos(with_timeline: true))

  # Open a request manually (most are opened by other flows via open!).
  def create
    req = ApprovalRequest.open!(
      client_id: current_client_id, request_type: params[:request_type].presence || 'other',
      subject_type: params[:subject_type], subject_id: params[:subject_id],
      payload: params[:payload] || {}, submitted_by: App.cu.id,
      submitted_by_name: App.cu.user_obj&.full_name, current_role: params[:current_role].presence || 'admin'
    )
    return_success(req.as_pos(with_timeline: true))
  end

  def comment
    item.record!('commented', actor_id: App.cu.id, actor_name: actor_name,
                 actor_role: actor_role, note: params[:note])
    return_success(item.as_pos(with_timeline: true))
  end

  def request_changes
    return_errors!("Request is already #{item.status}", 422) unless item.open?
    item.set(status: 'changes_requested', decision_reason: params[:reason])
    save(item) do
      item.record!('changes_requested', actor_id: App.cu.id, actor_name: actor_name,
                   actor_role: actor_role, note: params[:reason])
      return_success(item.as_pos(with_timeline: true))
    end
  end

  def approve
    req = item
    return_errors!("Request is already #{req.status}", 422) unless req.open?
    ok = App.db.transaction do
      apply_side_effects!(req)
      req.set(status: 'approved', decided_by: App.cu.id, decided_at: Time.now,
              decision_reason: params[:reason])
      req.save_changes
      req.record!('approved', actor_id: App.cu.id, actor_name: actor_name,
                  actor_role: actor_role, note: params[:reason])
      true
    end
    return_errors!('Could not approve the request', 422) unless ok
    App::Audit.record('approval.approve', entity: req, client_id: req.client_id,
                      summary: "Approved #{req.code} (#{req.request_type})")
    return_success(req.as_pos(with_timeline: true))
  end

  def reject
    return_errors!("Request is already #{item.status}", 422) unless item.open?
    item.set(status: 'rejected', decided_by: App.cu.id, decided_at: Time.now,
             decision_reason: params[:reason])
    save(item) do
      item.record!('rejected', actor_id: App.cu.id, actor_name: actor_name,
                   actor_role: actor_role, note: params[:reason])
      App::Audit.record('approval.reject', entity: item, client_id: item.client_id,
                        summary: "Rejected #{item.code} (#{item.request_type})")
      return_success(item.as_pos(with_timeline: true))
    end
  end

  def item(id = rp[:id]) = (@item ||= scoped[id] || return_errors!('Request not found', 404))

  private

  def actor_name = App.cu.user_obj&.full_name
  def actor_role = App.cu.user_obj&.role_name

  # Type-specific effect applied inside the approve transaction. Each lookup is
  # client-scoped so a request can only ever touch its own venture's data.
  def apply_side_effects!(req)
    p = req.payload || {}
    case req.request_type
    when 'owner_verification'
      if (u = scoped_user(p['user_id']))
        u.set(kyc_status: 'verified', verified_at: Time.now, verified_by: App.cu.id, active: true)
        u.save_changes
      end
      mark_plot_verified(p['plot_id'])
    when 'document_verification'
      if (d = Document.where(client_id: req.client_id, id: p['document_id']).first)
        d.set(approved: true, approved_by: actor_name, approved_at: Time.now)
        d.save_changes
      end
    when 'plot_claim'
      mark_plot_verified(p['plot_id'])
      # Phase 2 extends ownership_transfer side effects.
    end
  end

  def scoped_user(id)
    id && User.where(client_id: current_client_id, id: id).first
  end

  def mark_plot_verified(plot_id)
    return unless plot_id
    plot = Plot.where(client_id: current_client_id, id: plot_id).first
    return unless plot
    plot.set(membership: 'verified', status: (plot.status == 'available' ? 'booked' : plot.status))
    plot.save_changes
  end

  def counts_by_status
    base = scoped
    { all: base.count,
      open: base.where(status: ApprovalRequest::OPEN_STATUSES).count,
      approved: base.where(status: 'approved').count,
      rejected: base.where(status: 'rejected').count }
  end
end
