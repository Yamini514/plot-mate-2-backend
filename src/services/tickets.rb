require 'time' # Time.parse for visit scheduling

class App::Services::Tickets < App::Services::Base
  def model = Ticket

  def list
    ds = scoped.order(Sequel.desc(:created_at))
    ds = ds.where(status: qs[:status])     if qs[:status].present?   && qs[:status]   != 'all'
    ds = ds.where(category: qs[:category]) if qs[:category].present? && qs[:category] != 'all'
    ds = ds.where(priority: qs[:priority]) if qs[:priority].present? && qs[:priority] != 'all'
    ds = ds.where(created_by_user_id: App.cu.id) if qs[:mine] == 'true'
    # Vendor portal: only the work orders assigned to this vendor's staff record
    # (-1 = a never-matching id when the login isn't linked to a vendor yet).
    ds = ds.where(assignee_staff_id: my_staff_id || -1) if qs[:assigned_to_me] == 'true'
    if qs[:search].present?
      term = "%#{qs[:search]}%"
      ds = ds.where do
        Sequel.ilike(:code, term) | Sequel.ilike(:subject, term) |
          Sequel.ilike(:created_by_name, term) | Sequel.ilike(:assignee, term) |
          Sequel.ilike(:location, term)
      end
    end
    count = ds.count
    return_success(ds.offset(offset).limit(limit).all.map(&:as_pos),
                   total_pages: (count / page_size.to_f).ceil, counts: counts_by_status)
  end

  def get
    enforce_vendor_scope!(item)
    return_success(item.as_pos.merge(photos: ticket_photos(item),
                                     materials: item.materials.map(&:as_pos),
                                     events: item.events.map(&:as_pos)))
  end

  # Vendor/admin comment on the timeline (internal by default).
  def add_comment
    enforce_vendor_scope!(item)
    validate!('body' => App::Validate.text(params[:body], min: 1, max: 2000, label: 'Comment'))
    internal = params.key?(:internal) ? !!params[:internal] : true
    log_event(item, kind: 'note', internal: internal, body: params[:body].to_s.strip)
    App::Audit.record('ticket.comment', entity: item, client_id: current_client_id, summary: "Comment on #{item.code}")
    return_success(item.as_pos.merge(events: item.events_dataset.all.map(&:as_pos)))
  end

  # Vendor commits to a site-visit date.
  def schedule_visit
    enforce_vendor_scope!(item)
    at = params[:scheduled_visit_at].present? ? (Time.parse(params[:scheduled_visit_at].to_s) rescue nil) : nil
    return_errors!('A valid visit date is required', 422) unless at
    item.update(scheduled_visit_at: at)
    log_event(item, kind: 'visit', internal: false, body: "Site visit scheduled for #{at.strftime('%d %b %Y %H:%M')}")
    App::Audit.record('ticket.schedule_visit', entity: item, client_id: current_client_id, summary: "Visit scheduled for #{item.code}")
    return_success(item.as_pos.merge(events: item.events_dataset.all.map(&:as_pos)))
  end

  def create
    obj = model.new(data_for(:save))
    obj.client_id = current_client_id
    obj.code ||= next_code
    obj.status = 'created'
    obj.reopen_count = 0
    obj.created_by_name ||= "#{App.cu.user_obj.full_name} (#{App.cu.user_obj.role_name.capitalize})"
    obj.created_by_user_id ||= App.cu.id
    obj.due_at = Time.now + (Ticket::SLA_HOURS[obj.priority] || 24) * 3600
    save(obj) do |t|
      attach_photos_from_params(t)   # optional photos posted with the request
      return_success(t.as_pos.merge(photos: ticket_photos(t)))
    end
  end

  def update
    data = data_for(:save)
    item.set_fields(data, data.keys)
    save(item) { |t| return_success(t.as_pos) }
  end

  # Workflow transition (validated by the state machine).
  def transition
    enforce_vendor_scope!(item)
    to = params[:to].to_s
    unless item.transition!(to)
      return_errors!("Cannot move #{item.code} from '#{item.status}' to '#{to}'", 422)
    end
    return_success(item.as_pos)
  end

  # Assign to a specific vendor (assignee_staff_id), a named person, or
  # auto-assign by category.
  def assign
    if params[:assignee_staff_id].present?
      vendor = App::Models::Staff.where(client_id: current_client_id, id: params[:assignee_staff_id]).first
      return_errors!('Vendor not found', 404) unless vendor
      item.set(assignee: vendor.name, assignee_staff_id: vendor.id,
               status: (item.status == 'created' ? 'assigned' : item.status))
      save(item) do |t|
        log_event(t, kind: 'assignment', internal: false, body: "Assigned to #{vendor.name}")
        notify_vendor(vendor, kind: 'work_order', title: 'New work order assigned',
                      body: "#{t.code} — #{t.subject}", link: '/vendor')
        return_success(t.as_pos)
      end
    elsif params[:assignee].present?
      item.assignee = params[:assignee]
      item.status = 'assigned' if item.status == 'created'
      save(item) { |t| return_success(t.as_pos) }
    else
      item.auto_assign!
      return_success(item.as_pos)
    end
  end

  # Vendor accepts the assignment → starts work.
  def accept
    enforce_vendor_scope!(item)
    item.set(accepted_at: Time.now,
             status: (%w[assigned escalated].include?(item.status) ? 'accepted' : item.status))
    save(item) do |t|
      log_event(t, kind: 'status', internal: false, body: 'Vendor accepted the assignment')
      App::Audit.record('ticket.accept', entity: t, client_id: current_client_id, summary: "Accepted #{t.code}")
      return_success(t.as_pos)
    end
  end

  # Vendor declines → kicked back to the queue (unassigned) with a reason.
  def reject
    enforce_vendor_scope!(item)
    item.set(rejected_reason: params[:reason], assignee: nil, assignee_staff_id: nil,
             accepted_at: nil, status: 'escalated')
    save(item) do |t|
      App::Audit.record('ticket.vendor_reject', entity: t, client_id: current_client_id,
                        summary: "Vendor declined #{t.code}", meta: { reason: params[:reason] })
      return_success(t.as_pos)
    end
  end

  # Attach a before/after/general work photo (URL from the Uploads presign flow
  # or an inline data URL).
  def attach_photo
    enforce_vendor_scope!(item)
    return_errors!('A photo URL is required', 422) if params[:url].to_s.empty?
    photo = App::Models::Photo.new(
      client_id: current_client_id, url: params[:url], caption: params[:caption],
      kind: (params[:kind].presence || 'general'), category: 'work_order',
      attachable_type: 'Ticket', attachable_id: item.id, date: Date.today
    )
    photo.code ||= "WPH-#{App::Models::Photo.where(client_id: current_client_id).count + 1}"
    save(photo) { return_success(item.as_pos.merge(photos: ticket_photos(item))) }
  end

  # Mark the work done with a completion report (+ optional labour cost), then
  # notify the owner.
  def complete
    enforce_vendor_scope!(item)
    item.completion_note = params[:completion_note]
    item.labour_cost_paise = (params[:labour_cost].to_f * 100).round if params.key?(:labour_cost)
    item.set(status: 'resolved', resolved_at: (item.resolved_at || Time.now))
    save(item) do |t|
      log_event(t, kind: 'status', internal: false, body: 'Work completed — submitted for review')
      App::Audit.record('ticket.complete', entity: t, client_id: current_client_id, summary: "Completed #{t.code}")
      notify_owner!(t)
      return_success(t.as_pos.merge(photos: ticket_photos(t), materials: t.materials.map(&:as_pos),
                                    events: t.events_dataset.all.map(&:as_pos)))
    end
  end

  # --- work-order materials -----------------------------------------------
  def add_material
    enforce_vendor_scope!(item)
    validate!(
      'item'      => App::Validate.text(params[:item], min: 1, max: 120, label: 'Item'),
      'quantity'  => App::Validate.number(params[:quantity], positive: true, integer: true, required: false, label: 'Quantity'),
      'unit_cost' => App::Validate.number(params[:unit_cost], min: 0, required: false, label: 'Unit cost')
    )
    App::Models::WorkOrderMaterial.create(
      ticket_id: item.id, client_id: current_client_id, item: params[:item].to_s.strip,
      quantity: (params[:quantity] || 1).to_i, unit_cost_paise: (params[:unit_cost].to_f * 100).round,
      created_by: App.cu.id
    )
    recompute_materials!(item)
    log_event(item, kind: 'material', internal: true, body: "Added material: #{params[:item]} ×#{params[:quantity] || 1}")
    App::Audit.record('workorder.material.add', entity: item, client_id: current_client_id,
                      summary: "Added material '#{params[:item]}' to #{item.code}")
    return_success(item.as_pos.merge(materials: item.materials_dataset.all.map(&:as_pos)))
  end

  def remove_material
    enforce_vendor_scope!(item)
    m = App::Models::WorkOrderMaterial[client_id: current_client_id, ticket_id: item.id, id: rp[:material].to_i] ||
        return_errors!('Material not found', 404)
    m.destroy
    recompute_materials!(item)
    return_success(item.as_pos.merge(materials: item.materials_dataset.all.map(&:as_pos)))
  end

  def escalate
    item.status = 'escalated'
    save(item) { |t| return_success(t.as_pos) }
  end

  # Member confirms resolution: accept (close + rate) or reopen.
  def verify
    return_errors!('Forbidden', 403) unless item.created_by_user_id == App.cu.id
    case params[:action].to_s
    when 'accept'
      item.status = 'closed'
      item.rating = params[:rating]&.to_i
      save(item) { |t| return_success(t.as_pos) }
    when 'reopen'
      unless item.transition!('reopened')
        item.status = 'reopened'
        item.reopen_count = (item.reopen_count || 0) + 1
        item.resolved_at = nil
        item.save_changes
      end
      return_success(item.as_pos)
    else
      return_errors!('Invalid action', 400)
    end
  end

  # Helpdesk dashboard widgets. Vendor-scoped when called with assigned_to_me
  # (the vendor portal dashboard) so a vendor only sees their own counts.
  def summary
    ds = scoped
    ds = ds.where(assignee_staff_id: my_staff_id || -1) if qs[:assigned_to_me] == 'true'
    rows = ds.all
    by   = ->(s) { rows.count { |t| t.status == s } }
    done = rows.select { |t| t.resolved_at && t.created_at }
    avg  = done.empty? ? 0 : (done.sum { |t| t.resolved_at - t.created_at } / done.length / 3600.0).round(1)
    return_success(
      total:              rows.length,
      open:               rows.count { |t| Ticket::OPEN_STATUSES.include?(t.status) },
      in_progress:        by.call('in_progress'),
      resolved:           by.call('resolved'),
      closed:             by.call('closed'),
      escalated:          by.call('escalated'),
      overdue:            rows.count { |t| t.sla_state == 'breached' },
      reopened:           rows.count { |t| (t.reopen_count || 0).positive? },
      avg_resolution_hrs: avg,
      sla_compliance:     rows.empty? ? 100 : ((rows.count { |t| t.sla_state != 'breached' } * 100.0) / rows.length).round,
      staff_performance: rows.reject { |t| t.assignee.nil? }.group_by(&:assignee)
                             .map { |a, l| { name: a, value: l.length } }
                             .sort_by { |x| -x[:value] }.first(6),
      sla_by_priority: %w[critical high medium low].map do |p|
        within = rows.select { |t| t.priority == p }
        ok = within.count { |t| t.sla_state != 'breached' }
        { name: p.capitalize, value: within.empty? ? 100 : (ok * 100 / within.length) }
      end,
      category_distribution: rows.group_by(&:category).map { |c, l| { name: c, value: l.length } },
      status_distribution: [
        { name: 'Open',      value: rows.count { |t| Ticket::OPEN_STATUSES.include?(t.status) } },
        { name: 'Resolved',  value: by.call('resolved') },
        { name: 'Closed',    value: by.call('closed') },
        { name: 'Escalated', value: by.call('escalated') }
      ]
    )
  end

  def export_csv
    ds = scoped.order(Sequel.desc(:created_at))
    csv = CSV.generate do |out|
      out << %w[Ticket Subject Category Priority Status Assignee SLA Created]
      ds.each do |t|
        out << [t.code, t.subject, t.category, t.priority, t.status, t.assignee, t.sla_remaining, t.created_at]
      end
    end
    r.response['Content-Type'] = 'text/csv'
    r.response['Content-Disposition'] = 'attachment; filename="tickets.csv"'
    csv
  end

  def item(id = rp[:id])
    @item ||= scoped[id] || return_errors!('Ticket not found', 404)
  end

  # --- vendor payments (read-only) -------------------------------------------
  # Completed work orders for the calling vendor, with their cost + payment status.
  def vendor_payments
    ds = scoped.where(assignee_staff_id: my_staff_id, status: %w[resolved closed]).order(Sequel.desc(:resolved_at))
    return_success(ds.all.map(&:as_pos))
  end

  # Admin sets the payment status on a work order (pending|approved|paid).
  def set_payment_status
    st = params[:status].to_s
    return_errors!('Invalid status', 422) unless %w[pending approved paid].include?(st)
    item.update(payment_status: st)
    App::Audit.record('workorder.payment_status', entity: item, client_id: current_client_id,
                      summary: "#{item.code} payment → #{st}")
    # Notify the vendor when their payment is released.
    if st == 'paid' && item.assignee_staff_id
      v = App::Models::Staff[client_id: current_client_id, id: item.assignee_staff_id]
      notify_vendor(v, kind: 'payment', title: 'Payment released', body: "Payment released for #{item.code}", link: '/vendor/payments') if v
    end
    return_success(item.as_pos)
  end

  # --- vendor support tickets (vendor is the CREATOR) ------------------------
  def vendor_support_list
    ds = scoped.where(created_by_user_id: App.cu.id, category: 'support').order(Sequel.desc(:created_at))
    return_success(ds.all.map(&:as_pos))
  end

  def vendor_support_create
    validate!('subject' => App::Validate.text(params[:subject], min: 3, max: 160, label: 'Subject'),
              'description' => App::Validate.presence(params[:description], label: 'Description'))
    obj = model.new(
      client_id: current_client_id, subject: params[:subject], description: params[:description],
      category: 'support', priority: params[:priority].presence || 'medium', status: 'created',
      created_by_name: "#{App.cu.user_obj.full_name} (Vendor)", created_by_user_id: App.cu.id, reopen_count: 0
    )
    obj.code ||= next_code
    obj.due_at = Time.now + (Ticket::SLA_HOURS[obj.priority] || 24) * 3600
    save(obj) do |t|
      App::Audit.record('support.create', entity: t, client_id: current_client_id, summary: "Vendor support: #{t.subject}")
      return_success(t.as_pos)
    end
  end

  def vendor_support_get
    t = support_item
    return_success(t.as_pos.merge(events: t.events.map(&:as_pos)))
  end

  def vendor_support_reply
    t = support_item
    validate!('body' => App::Validate.text(params[:body], min: 1, max: 2000, label: 'Reply'))
    log_event(t, kind: 'note', internal: true, body: params[:body].to_s.strip)
    return_success(t.as_pos.merge(events: t.events_dataset.all.map(&:as_pos)))
  end

  # Support tickets are gated to their vendor CREATOR (not the assignee).
  def support_item(id = rp[:id])
    t = scoped[id] || return_errors!('Ticket not found', 404)
    return_errors!('Not allowed', 403) unless t.created_by_user_id == App.cu.id
    t
  end

  private

  # Notify a vendor's portal login (resolved from their staff_id) of an event.
  def notify_vendor(staff, kind:, title:, body:, link:)
    user = App::Models::User
           .where(client_id: current_client_id, role: App::Models::User::ROLES[:vendor], active: true).all
           .find { |u| u.extras&.dig('staff_id').to_s == staff.id.to_s }
    return unless user
    App::Notify.create(user_id: user.id, client_id: current_client_id, kind: kind,
                       title: title, body: body, link: link)
  end

  # Append a work-order timeline entry, stamped with the acting user.
  def log_event(ticket, kind:, body:, internal: true, meta: {})
    u = App.cu.user_obj
    App::Models::TicketEvent.create(
      ticket_id: ticket.id, client_id: ticket.client_id, kind: kind, body: body,
      internal: internal, actor_name: u&.full_name, actor_id: u&.id, meta: meta || {}
    )
  rescue => e
    App.logger.error("ticket event log failed: #{e.message}")
    nil
  end

  # Recompute the cached materials total on the ticket from its line items.
  def recompute_materials!(ticket)
    total = ticket.materials_dataset.all.sum(&:line_total_paise)
    ticket.update(materials_cost_paise: total)
  end

  # The staff record id behind the logged-in vendor's portal login (set when the
  # admin creates the login). nil for admins / unlinked logins.
  def my_staff_id
    App.cu.user_obj.extras&.dig('staff_id')
  end

  # A vendor may only act on work orders assigned to their own staff record.
  # No-op for admins (who operate every ticket on the vendor's behalf).
  def enforce_vendor_scope!(t)
    u = App.cu.user_obj
    return unless u&.vendor?
    sid = my_staff_id
    unless sid && t.assignee_staff_id.to_s == sid.to_s
      return_errors!('This work order is not assigned to you', 403)
    end
  end

  def counts_by_status
    c = scoped.group_and_count(:status).all
              .each_with_object({}) { |r, h| h[r[:status]] = r[:count] }
    c['all'] = scoped.count
    c
  end

  def next_code
    "TKT-#{4811 + scoped.count}"
  end

  def ticket_photos(t)
    App::Models::Photo
      .where(client_id: current_client_id, attachable_type: 'Ticket', attachable_id: t.id)
      .order(:created_at).all.map(&:as_pos)
  end

  # Persist any photos posted alongside a create (member helpdesk / admin form).
  # Accepts an array of { url, kind, caption } (or bare URL strings). Best-effort.
  def attach_photos_from_params(t)
    list = params[:photos]
    return unless list.is_a?(Array)
    list.first(8).each do |ph|
      url = ph.is_a?(Hash) ? (ph['url'] || ph[:url]) : ph
      next if url.to_s.strip.empty?
      kind = (ph.is_a?(Hash) ? (ph['kind'] || ph[:kind]) : nil).to_s
      photo = App::Models::Photo.new(
        client_id: current_client_id, url: url,
        caption: (ph.is_a?(Hash) ? (ph['caption'] || ph[:caption]) : nil),
        kind: (kind.empty? ? 'general' : kind), category: 'work_order',
        attachable_type: 'Ticket', attachable_id: t.id, date: Date.today
      )
      photo.code ||= "WPH-#{App::Models::Photo.where(client_id: current_client_id).count + 1}"
      photo.save
    end
  rescue => e
    App.logger.error("attach_photos_from_params failed: #{e.message}")  # non-fatal
  end

  # Best-effort: email the ticket's owner when their work order is completed.
  def notify_owner!(t)
    return unless t.created_by_user_id
    owner = User.where(client_id: current_client_id, id: t.created_by_user_id).first
    return unless owner&.email
    client = Client[current_client_id]
    html = App::Mailer.branded_email(
      client: client, heading: "Your request #{t.code} is resolved",
      intro: "Hello #{owner.full_name}, work on \"#{t.subject}\" is complete." \
             "#{t.completion_note ? " Notes: #{t.completion_note}" : ''}",
      outro: 'Please confirm closure or reopen it from your portal if anything remains.'
    )
    App::Mailer.deliver(to: owner.email, subject: "#{t.code} resolved", html_body: html, client: client)
  rescue => e
    App.logger.error("notify_owner! failed: #{e.message}")  # non-fatal
  end

  def self.fields
    { save: %i[subject description category priority location] }
  end
end
