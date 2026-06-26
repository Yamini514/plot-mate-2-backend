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

  def get
    req = item
    data = req.as_pos(with_timeline: true)
    # Surface the submitted KYC (id type/number, address, uploaded document) so
    # the reviewer can actually verify it, not just see the user_id.
    data[:kyc] = subject_kyc(req) if req.subject_type == 'User'
    return_success(data)
  end

  # Open a request manually (most are opened by other flows via open!).
  def create
    req = ApprovalRequest.open!(
      client_id: current_client_id, request_type: params[:request_type].presence || 'other',
      subject_type: params[:subject_type], subject_id: params[:subject_id],
      payload: params[:payload] || {}, submitted_by: App.cu.id,
      submitted_by_name: App.cu.user_obj&.full_name, current_role: params[:current_role].presence
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
      App::Notify.create(user_id: item.submitted_by, client_id: item.client_id, kind: item.request_type,
                         title: 'Changes requested',
                         body: "Your request #{item.code} needs changes: #{params[:reason]}",
                         link: '/member/requests', entity: item)
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
    App::Notify.create(user_id: req.submitted_by, client_id: req.client_id, kind: req.request_type,
                       title: 'Request approved',
                       body: "Your #{req.request_type.to_s.tr('_', ' ')} request #{req.code} was approved.",
                       link: '/member/requests', entity: req)
    return_success(req.as_pos(with_timeline: true))
  end

  def reject
    return_errors!("Request is already #{item.status}", 422) unless item.open?
    apply_reject_side_effects!(item)
    item.set(status: 'rejected', decided_by: App.cu.id, decided_at: Time.now,
             decision_reason: params[:reason])
    save(item) do
      item.record!('rejected', actor_id: App.cu.id, actor_name: actor_name,
                   actor_role: actor_role, note: params[:reason])
      App::Audit.record('approval.reject', entity: item, client_id: item.client_id,
                        summary: "Rejected #{item.code} (#{item.request_type})")
      App::Notify.create(user_id: item.submitted_by, client_id: item.client_id, kind: item.request_type,
                         title: 'Request rejected',
                         body: "Your #{item.request_type.to_s.tr('_', ' ')} request #{item.code} was rejected: #{params[:reason]}",
                         link: '/member/requests', entity: item)
      return_success(item.as_pos(with_timeline: true))
    end
  end

  def item(id = rp[:id]) = (@item ||= scoped[id] || return_errors!('Request not found', 404))

  # --- member (owner) self-service: track + act on OWN requests only ---------
  def member_list
    ds = ApprovalRequest.where(client_id: current_client_id, submitted_by: App.cu.id)
                        .order(Sequel.desc(:created_at))
    ds = ds.where(status: qs[:status]) if qs[:status].present? && qs[:status] != 'all'
    return_success(ds.all.map(&:as_pos))
  end

  def member_get = return_success(member_item.as_pos(with_timeline: true))

  # Owner attaches an additional supporting document to their own request.
  def member_attach_document
    req = member_item
    validate!('name' => App::Validate.presence(params[:name], label: 'File name'),
              'url'  => App::Validate.presence(params[:url], label: 'File'))
    payload = req.payload || {}
    docs = Array(payload['documents']) + [{ 'name' => params[:name], 'url' => params[:url] }]
    req.update(payload: payload.merge('documents' => docs))
    req.record!('document_added', actor_id: App.cu.id, actor_name: actor_name, note: params[:name])
    return_success(req.as_pos(with_timeline: true))
  end

  # Owner re-submits a request the association sent back for changes.
  def member_resubmit
    req = member_item
    return_errors!('Only a request awaiting changes can be resubmitted', 422) unless req.status == 'changes_requested'
    req.update(status: 'submitted')
    req.record!('resubmitted', actor_id: App.cu.id, actor_name: actor_name, note: params[:note])
    App::Audit.record('approval.resubmit', entity: req, client_id: req.client_id, summary: "Resubmitted #{req.code}")
    return_success(req.as_pos(with_timeline: true))
  end

  def member_item(id = rp[:id])
    @member_item ||= (ApprovalRequest[client_id: current_client_id, id: id, submitted_by: App.cu.id] ||
                      return_errors!('Request not found', 404))
  end

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
      claim_plot!(p)
    when 'ownership_transfer'
      t = Transfer.where(client_id: req.client_id, id: p['transfer_id']).first
      t&.complete!(decided_by: App.cu.id)
    end
  end

  # Reflect a rejection back onto a linked record where it matters (so a
  # rejected transfer doesn't sit "under_review" forever).
  def apply_reject_side_effects!(req)
    return unless req.request_type == 'ownership_transfer'
    t = Transfer.where(client_id: req.client_id, id: (req.payload || {})['transfer_id']).first
    t&.reject!(decided_by: App.cu.id, reason: params[:reason])
  end

  def scoped_user(id)
    id && User.where(client_id: current_client_id, id: id).first
  end

  # KYC snapshot for the request's subject user, shown in the review drawer.
  def subject_kyc(req)
    u = scoped_user(req.subject_id) || scoped_user((req.payload || {})['user_id'])
    return nil unless u
    k = u.kyc_data || {}
    { status: u.kyc_status, full_name: u.full_name, email: u.email, phone: u.phone_number,
      id_type: k['id_type'], id_number: k['id_number'], address: k['address'],
      id_document: k['id_document'] }
  end

  def mark_plot_verified(plot_id)
    return unless plot_id
    plot = Plot.where(client_id: current_client_id, id: plot_id).first
    return unless plot
    plot.set(membership: 'verified', status: (plot.status == 'available' ? 'booked' : plot.status))
    plot.save_changes
  end

  # Approving a plot_claim links the plot to the claimant: copy their contact
  # onto the registry record, link the user's profile to the plot_no, and verify.
  def claim_plot!(p)
    plot = Plot.where(client_id: current_client_id, id: p['plot_id']).first
    return unless plot
    if (u = scoped_user(p['user_id']))
      plot.owner_name = u.full_name
      plot.email = u.email
      plot.phone = u.phone_number if u.phone_number.to_s =~ /\A\d{10}\z/
      u.set(extras: (u.extras || {}).merge('plot_no' => plot.plot_no))
      u.save_changes
    end
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
