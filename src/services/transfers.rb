class App::Services::Transfers < App::Services::Base
  # Ownership transfers. Initiating one snapshots the current owner + outstanding
  # dues and opens an 'ownership_transfer' approval request; approving that
  # request (in the Approvals queue) relinks the plot to the new owner.
  # Tenant-scoped to the admin's venture.
  def model = Transfer

  def list
    ds = scoped.order(Sequel.desc(:created_at))
    ds = ds.where(status: qs[:status]) if qs[:status].present? && qs[:status] != 'all'
    rows  = ds.all
    plots = Plot.where(client_id: current_client_id, id: rows.map(&:plot_id).uniq).select_hash(:id, :plot_no)
    return_success(rows.map { |t| t.as_pos.merge(plot_no: plots[t.plot_id]) }, counts: counts_by_status)
  end

  def get
    t = item
    plot = Plot.where(client_id: current_client_id, id: t.plot_id).first
    return_success(t.as_pos.merge(plot_no: plot&.plot_no))
  end

  # Initiate: snapshot the plot's current owner + dues, then raise the approval.
  def initiate
    plot = Plot.where(client_id: current_client_id, id: params[:plot_id]).first
    return_errors!('Plot not found in this venture', 404) unless plot
    open_transfer!(plot, audit_action: 'transfer.initiate')
  end

  # Owner-initiated transfer of their OWN plot (Owner Portal). Same flow as
  # admin initiate, gated to a plot the caller owns.
  def member_initiate
    plot = Plot.where(client_id: current_client_id, id: params[:plot_id]).first
    return_errors!('Plot not found', 404) unless plot
    return_errors!('You can only transfer a plot you own', 403) unless owns_plot?(plot)
    open_transfer!(plot, audit_action: 'transfer.member_initiate')
  end

  # Owner's own transfers (by the plots they own).
  def member_list
    ids = my_plot_ids
    rows  = ids.empty? ? [] : Transfer.where(client_id: current_client_id, plot_id: ids).order(Sequel.desc(:created_at)).all
    plots = Plot.where(client_id: current_client_id, id: rows.map(&:plot_id).uniq).select_hash(:id, :plot_no)
    return_success(rows.map { |t| t.as_pos.merge(plot_no: plots[t.plot_id]) })
  end

  def member_attach_document
    @item = member_item
    attach_document
  end

  # Attach a supporting document (sale deed / NOC). URL comes from the shared
  # Uploads presign flow (or inline data URL fallback).
  def attach_document
    doc = { 'name' => params[:name], 'url' => params[:url],
            'doc_type' => params[:doc_type].presence || 'other' }
    return_errors!('A document name and URL are required', 422) if doc['name'].to_s.empty? || doc['url'].to_s.empty?
    item.set(docs: (item.docs || []) + [doc])
    save(item) { return_success(item.as_pos) }
  end

  def cancel
    return_errors!('Only open transfers can be cancelled', 422) unless item.open?
    item.set(status: 'cancelled')
    save(item) { return_success(item.as_pos) }
  end

  def item(id = rp[:id]) = (@item ||= scoped[id] || return_errors!('Transfer not found', 404))

  private

  # Shared transfer-open flow (admin initiate + member_initiate): snapshot the
  # owner + dues, persist the transfer, and raise the ownership_transfer approval.
  def open_transfer!(plot, audit_action:)
    return_errors!('New owner name is required', 422) if params[:to_owner_name].to_s.strip.empty?
    t = Transfer.new(
      client_id: current_client_id, plot_id: plot.id,
      from_owner_name: plot.owner_name, from_email: plot.email, from_phone: plot.phone,
      to_owner_name: params[:to_owner_name], to_email: params[:to_email].presence,
      to_phone: params[:to_phone].presence, reason: params[:reason].presence || 'sale',
      outstanding_paise: plot.amount_due_paise, status: 'under_review', docs: [],
      dues_action: (params[:dues_action].to_s == 'clear' ? 'clear' : 'carry')
    )
    t.code ||= "TRF-#{1001 + Transfer.where(client_id: current_client_id).count}"
    ok = App.db.transaction do
      raise Sequel::Rollback unless t.save
      req = App::Models::ApprovalRequest.open!(
        client_id: current_client_id, request_type: 'ownership_transfer',
        subject_type: 'Transfer', subject_id: t.id,
        payload: { 'transfer_id' => t.id, 'plot_id' => plot.id, 'plot_no' => plot.plot_no,
                   'to_owner_name' => t.to_owner_name },
        submitted_by: App.cu.id, submitted_by_name: App.cu.user_obj&.full_name
      )
      t.update(approval_request_id: req.id)
      true
    end
    return_errors!('Could not initiate the transfer', 422) unless ok
    App::Audit.record(audit_action, entity: t, client_id: current_client_id,
                      summary: "Initiated transfer #{t.code} for plot #{plot.plot_no}")
    return_success(t.as_pos.merge(plot_no: plot.plot_no))
  end

  def owns_plot?(plot)
    u = App.cu.user_obj
    pno = u.extras&.dig('plot_no')
    (pno.present? && plot.plot_no == pno) || (plot.owner_name.present? && plot.owner_name == u.full_name)
  end

  def my_plot_ids
    u = App.cu.user_obj
    pno = u.extras&.dig('plot_no')
    ds = Plot.where(client_id: current_client_id, active: true)
    (pno.present? ? ds.where(plot_no: pno) : ds.where(owner_name: u.full_name)).select_map(:id)
  end

  def member_item(id = rp[:id])
    t = Transfer[client_id: current_client_id, id: id] || return_errors!('Transfer not found', 404)
    return_errors!('Not allowed', 403) unless my_plot_ids.include?(t.plot_id)
    t
  end

  def counts_by_status
    base = scoped
    { all: base.count, open: base.where(status: Transfer::OPEN_STATUSES).count,
      completed: base.where(status: 'completed').count,
      rejected: base.where(status: 'rejected').count }
  end
end
