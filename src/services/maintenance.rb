require 'date'

class App::Services::Maintenance < App::Services::Base
  # Preventive / recurring maintenance schedules and their completion logs.
  # Tenant-scoped. Logging a completion rolls the schedule forward and, if an
  # issue was found, raises a helpdesk ticket so it joins the normal work queue.
  def model = MaintenanceSchedule

  def list
    ds = scoped.order(Sequel.asc(:next_due_on))
    ds = ds.where(active: true)  if qs[:status] == 'active'
    ds = ds.where(active: false) if qs[:status] == 'inactive'
    rows = ds.all
    return_success(rows.map(&:as_pos), counts: counts)
  end

  def get
    s = item
    return_success(s.as_pos.merge(logs: s.maintenance_logs.map(&:as_pos)))
  end

  def create
    s = MaintenanceSchedule.new(data_for(:save))
    s.client_id = current_client_id
    s.code ||= "PM-#{1001 + scoped.count}"
    s.next_due_on ||= start_due_date(s)
    set_assignee(s)
    save(s) { |row| return_success(row.as_pos) }
  end

  def update
    data = data_for(:save)
    item.set_fields(data, data.keys)
    set_assignee(item)
    save(item) { |row| return_success(row.as_pos) }
  end

  def toggle_active
    item.set(active: !item.active)
    save(item) { return_success(item.as_pos) }
  end

  # Record that an inspection was performed. Stores the report, advances the
  # schedule, and (when outcome=issue_found) opens a ticket for the fix.
  def log_completion
    s = item
    performed = parse_date(params[:performed_on]) || Date.today
    outcome   = params[:outcome].to_s == 'issue_found' ? 'issue_found' : 'ok'

    log = App::Models::MaintenanceLog.new(
      client_id: current_client_id, schedule_id: s.id, performed_on: performed,
      performed_by: params[:performed_by].presence || App.cu.user_obj&.full_name,
      outcome: outcome, report: params[:report]
    )
    log.code ||= "PMLOG-#{1001 + App::Models::MaintenanceLog.where(client_id: current_client_id).count}"

    ok = App.db.transaction do
      raise Sequel::Rollback unless log.save
      log.update(ticket_id: raise_issue_ticket!(s, params[:report]).id) if outcome == 'issue_found'
      s.advance!(performed)
      true
    end
    return_errors!('Could not record the inspection', 422) unless ok
    return_success(log.as_pos)
  end

  def item(id = rp[:id]) = (@item ||= scoped[id] || return_errors!('Schedule not found', 404))

  private

  def set_assignee(s)
    return if params[:assignee_staff_id].to_s.empty?
    v = App::Models::Staff.where(client_id: current_client_id, id: params[:assignee_staff_id]).first
    s.set(assignee_staff_id: v&.id, assignee_name: v&.name) if v
  end

  # Open a helpdesk ticket so a found issue is tracked like any other work order.
  def raise_issue_ticket!(s, note)
    t = Ticket.new(
      client_id: current_client_id, subject: "Inspection issue: #{s.title}",
      description: note, category: (s.category.presence || 'maintenance'),
      priority: 'high', status: 'created', location: s.area,
      created_by_name: "Preventive maintenance (#{s.code})", created_by_user_id: App.cu.id
    )
    t.code = "TKT-#{4811 + Ticket.where(client_id: current_client_id).count}"
    t.due_at = Time.now + (Ticket::SLA_HOURS['high'] || 8) * 3600
    t.save
    t
  end

  def start_due_date(s)
    Date.today + (MaintenanceSchedule::FREQUENCIES[s.frequency] || 30)
  end

  def parse_date(v)
    return nil if v.to_s.strip.empty?
    Date.parse(v.to_s)
  rescue ArgumentError
    nil
  end

  def counts
    base = scoped
    rows = base.all
    { all: rows.length, active: rows.count(&:active),
      overdue: rows.count { |s| s.due_state == 'overdue' },
      due_soon: rows.count { |s| s.due_state == 'due_soon' } }
  end

  def self.fields
    { save: %i[title category area frequency next_due_on notes] }
  end
end
