class App::Services::Complaints < App::Services::Base
  def model = Complaint

  def list
    ds = scoped.order(Sequel.desc(:created_at))
    ds = ds.where(status: qs[:status])     if qs[:status].present? && qs[:status] != 'all'
    ds = ds.where(priority: qs[:priority]) if qs[:priority].present?
    ds = ds.where(raised_by_user_id: App.cu.id) if qs[:mine] == 'true'
    if qs[:search].present?
      term = "%#{qs[:search]}%"
      ds = ds.where { Sequel.ilike(:title, term) | Sequel.ilike(:code, term) | Sequel.ilike(:raised_by, term) }
    end
    count = ds.count
    return_success(ds.offset(offset).limit(limit).all.map(&:as_pos),
                   total_pages: (count / page_size.to_f).ceil, counts: counts_by_status)
  end

  def get
    caller_can_act!   # admins: any complaint in their venture; members: only their own
    data = item.as_pos(with_events: true)
    # Members never see internal notes — only resident-visible timeline entries.
    data[:events] = data[:events].reject { |e| e[:internal] } unless App.cu.user_obj&.admin?
    return_success(data)
  end

  def create
    validate!(
      'title'    => App::Validate.text(params[:title], min: 3, max: 160),
      'priority' => App::Validate.text(params[:priority], required: false, max: 20)
    )
    obj = model.new(data_for(:save))
    obj.client_id = current_client_id
    obj.code ||= next_code
    obj.status = 'open'                                   # new complaints start open
    obj.raised_by ||= App.cu.user_obj.full_name
    obj.raised_by_user_id ||= App.cu.id
    obj.plot_no ||= App.cu.user_obj.extras&.dig('plot_no')
    # Optional photos/videos attached at raise time (jsonb [{name,url}]).
    obj.attachments = Array(params[:attachments]) if params.key?(:attachments)
    save(obj) do |c|
      App::Audit.record('complaint.create', entity: c, client_id: c.client_id,
                        summary: "Raised complaint #{c.code} — #{c.title}")
      return_success(c.as_pos(with_events: true))
    end
  end

  def update
    data = data_for(:save)
    item.set_fields(data, data.keys)
    save(item) { |c| return_success(c.as_pos(with_events: true)) }
  end

  def assign
    name = params[:assigned_to].presence || 'Maintenance Team'
    item.assigned_to    = name
    item.assigned_phone = params[:assigned_phone] if params.key?(:assigned_phone)
    item.assigned_email = params[:assigned_email] if params.key?(:assigned_email)
    item.assigned_to_user_id = params[:assigned_to_user_id] if params.key?(:assigned_to_user_id)
    item.status = 'in_progress' if item.status == 'open'
    save(item) do |c|
      log_event(c, kind: 'assignment', internal: true, body: "Assigned to #{name}")
      App::Audit.record('complaint.assign', entity: c, client_id: c.client_id,
                        summary: "Assigned #{c.code} to #{name}")
      if c.assigned_to_user_id
        App::Notify.create(user_id: c.assigned_to_user_id, client_id: c.client_id, kind: 'complaint',
                           title: 'Complaint assigned to you',
                           body: "#{c.code} — #{c.title}", link: '/vendor/complaints')
      end
      return_success(c.as_pos(with_events: true))
    end
  end

  def resolve
    from = item.status
    item.set(status: 'resolved', resolved_at: Time.now)
    save(item) do |c|
      log_event(c, kind: 'status', internal: false, body: 'Marked resolved', meta: { from: from, to: 'resolved' })
      App::Audit.record('complaint.resolve', entity: c, client_id: c.client_id,
                        summary: "Resolved #{c.code}", meta: { from: from })
      App::Notify.create(user_id: c.raised_by_user_id, client_id: c.client_id, kind: 'complaint',
                         title: 'Complaint resolved',
                         body: "#{c.code} — #{c.title} was marked resolved. Please confirm or reopen.",
                         link: '/member/complaints', entity: c)
      return_success(c.as_pos(with_events: true))
    end
  end

  # Raise the escalation ladder l1 → l2 → l3 (caps at l3). Independent of status.
  def escalate
    return_errors!('Already at the highest escalation level', 422) if item.escalation_level == 'l3'
    next_level = Complaint::NEXT_ESCALATION[item.escalation_level]
    item.set(escalation_level: next_level, escalated_at: Time.now)
    save(item) do |c|
      log_event(c, kind: 'escalation', internal: true,
                body: "Escalated to #{next_level}", meta: { reason: params[:reason] })
      App::Audit.record('complaint.escalate', entity: c, client_id: c.client_id,
                        summary: "Escalated #{c.code} to #{next_level}", meta: { reason: params[:reason] })
      return_success(c.as_pos(with_events: true))
    end
  end

  # Reopen a resolved/closed complaint (admin or the original raiser).
  def reopen
    caller_can_act!
    return_errors!('Only a resolved or closed complaint can be reopened', 422) unless %w[resolved closed].include?(item.status)
    validate!('reason' => App::Validate.text(params[:reason], min: 3, max: 500))
    from = item.status
    item.set(status: 'in_progress', resolved_at: nil, closed_at: nil,
             resident_confirmed: false, resident_confirmed_at: nil,
             reopen_count: (item.reopen_count || 0) + 1)
    save(item) do |c|
      log_event(c, kind: 'reopen', internal: false,
                body: params[:reason], meta: { from: from, to: 'in_progress' })
      App::Audit.record('complaint.reopen', entity: c, client_id: c.client_id,
                        summary: "Reopened #{c.code}", meta: { from: from, reason: params[:reason] })
      return_success(c.as_pos(with_events: true))
    end
  end

  # Resident confirms the resolution → close the complaint.
  def confirm_resolution
    caller_can_act!
    return_errors!('Only a resolved complaint can be confirmed', 422) unless item.status == 'resolved'
    item.set(status: 'closed', closed_at: Time.now,
             resident_confirmed: true, resident_confirmed_at: Time.now)
    save(item) do |c|
      log_event(c, kind: 'confirmation', internal: false, body: 'Resident confirmed the resolution')
      App::Audit.record('complaint.confirm', entity: c, client_id: c.client_id,
                        summary: "Resident confirmed resolution of #{c.code}")
      return_success(c.as_pos(with_events: true))
    end
  end

  # Add an internal note (default) or a resident-visible update to the timeline.
  def add_note
    validate!('body' => App::Validate.text(params[:body], min: 1, max: 2000, label: 'Note'))
    internal = params.key?(:internal) ? !!params[:internal] : true
    log_event(item, kind: 'note', internal: internal, body: params[:body].to_s.strip)
    App::Audit.record('complaint.note', entity: item, client_id: item.client_id,
                      summary: "Note on #{item.code}", meta: { internal: internal })
    return_success(item.as_pos(with_events: true))
  end

  # Attach a file (already uploaded via /admin/uploads/presign) to the complaint.
  def attach
    name = params[:name].to_s
    url  = params[:url].to_s
    validate!(
      'name' => App::Validate.presence(name, label: 'File name'),
      'url'  => App::Validate.presence(url, label: 'File'),
      'file' => App::Validate.file(name: name, size: params[:size])
    )
    list = (item.attachments || []) + [{ 'name' => name, 'url' => url,
                                         'key' => params[:key], 'size' => params[:size] }]
    item.set(attachments: list)
    save(item) do |c|
      log_event(c, kind: 'attachment', internal: true, body: "Attached #{name}")
      App::Audit.record('complaint.attach', entity: c, client_id: c.client_id,
                        summary: "Attached #{name} to #{c.code}")
      return_success(c.as_pos(with_events: true))
    end
  end

  # --- vendor execution: complaints assigned to the calling vendor -----------
  def vendor_list
    ds = scoped.where(assigned_to_user_id: App.cu.id).order(Sequel.desc(:created_at))
    ds = ds.where(status: qs[:status]) if qs[:status].present? && qs[:status] != 'all'
    return_success(ds.all.map(&:as_pos))
  end

  def vendor_get
    vendor_owns!
    data = item.as_pos(with_events: true)
    data[:events] = data[:events].reject { |e| e[:internal] } # vendor sees the public progress trail
    return_success(data)
  end

  # Vendor posts a progress update (resident-visible) on an assigned complaint.
  def vendor_note
    vendor_owns!
    params[:internal] = false
    add_note
  end

  def vendor_attach
    vendor_owns!
    attach
  end

  # Vendor marks the work resolved → the owner then confirms (OP-5).
  def vendor_resolve
    vendor_owns!
    resolve
  end

  def summary
    ds = scoped
    return_success(
      total:       ds.count,
      open:        ds.where(status: 'open').count,
      in_progress: ds.where(status: 'in_progress').count,
      resolved:    ds.where(status: 'resolved').count,
      high:        ds.where(priority: 'high').count
    )
  end

  def item(id = rp[:id])
    @item ||= scoped[id] || return_errors!('Complaint not found', 404)
  end

  private

  # Append a timeline entry, stamped with the acting user.
  def log_event(complaint, kind:, body:, internal: true, meta: {})
    u = App.cu.user_obj
    App::Models::ComplaintEvent.create(
      complaint_id: complaint.id, client_id: complaint.client_id,
      kind: kind, body: body, internal: internal,
      actor_name: u&.full_name, actor_id: u&.id, meta: meta || {}
    )
  rescue => e
    App.logger.error("complaint event log failed: #{e.message}")
    nil
  end

  # Vendor actions are limited to complaints assigned to that vendor.
  def vendor_owns!
    return if item.assigned_to_user_id == App.cu.id
    return_errors!('This complaint is not assigned to you', 403)
  end

  # Member-facing actions (reopen/confirm) are limited to the original raiser;
  # admins may act on any complaint in their venture.
  def caller_can_act!
    u = App.cu.user_obj
    return if u&.admin?
    return if item.raised_by_user_id == App.cu.id
    return_errors!('Not allowed for this complaint', 403)
  end

  def counts_by_status
    c = scoped.group_and_count(:status).all
              .each_with_object({}) { |r, h| h[r[:status]] = r[:count] }
    c['all'] = scoped.count
    c
  end

  def next_code
    "CMP-#{format('%03d', scoped.count + 1)}"
  end

  def self.fields
    { save: %i[title description category priority plot_no status assigned_to assigned_phone assigned_email assigned_to_user_id] }
  end
end
