class App::Models::MaintenanceSchedule < Sequel::Model
  one_to_many :maintenance_logs, key: :schedule_id, order: Sequel.desc(:created_at)

  FREQUENCIES = { 'weekly' => 7, 'monthly' => 30, 'quarterly' => 91,
                  'half_yearly' => 182, 'yearly' => 365 }.freeze

  def validate
    super
    validates_presence [:client_id, :title]
    validates_includes FREQUENCIES.keys, :frequency if frequency
  end

  def interval_days = FREQUENCIES[frequency] || 30

  # Roll the schedule forward after a completion: stamp last_done and compute
  # the next due date from the frequency.
  def advance!(performed_on)
    base = performed_on || Date.today
    set(last_done_on: base, next_due_on: base + interval_days)
    save_changes
  end

  # 'overdue' if past due, 'due_soon' within 7 days, else 'ok'.
  def due_state
    return 'inactive' unless active
    return 'unscheduled' unless next_due_on
    today = Date.today
    if next_due_on < today then 'overdue'
    elsif (next_due_on - today) <= 7 then 'due_soon'
    else 'ok'
    end
  end

  def as_pos
    { id: id, code: code, title: title, category: category, area: area,
      frequency: frequency, next_due_on: next_due_on, last_done_on: last_done_on,
      assignee_staff_id: assignee_staff_id, assignee_name: assignee_name,
      notes: notes, active: !!active, due_state: due_state, created_at: created_at }
  end
end
