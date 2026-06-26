class App::Models::Ticket < Sequel::Model
  one_to_many :materials, class: 'App::Models::WorkOrderMaterial', key: :ticket_id, order: :created_at

  CATEGORIES = %w[maintenance security electrical plumbing cleaning amenities
                  parking documentation billing community other].freeze
  PRIORITIES = %w[low medium high critical].freeze
  STATUSES   = %w[created assigned accepted in_progress pending_approval
                  resolved closed escalated reopened cancelled].freeze

  # SLA target hours by priority.
  SLA_HOURS = { 'low' => 72, 'medium' => 24, 'high' => 8, 'critical' => 1 }.freeze

  # Category → default assignee/team.
  ASSIGNMENT_MAP = {
    'electrical' => 'Ramesh (Electrician)', 'plumbing' => 'Mahesh (Plumber)',
    'security' => 'Suraj (Security Manager)', 'billing' => 'Lakshmi (Accountant)',
    'amenities' => 'Priya (Community Manager)', 'community' => 'Priya (Community Manager)',
    'maintenance' => 'Vendor — FixIt Facilities', 'cleaning' => 'Housekeeping Supervisor',
    'parking' => 'Facility Desk', 'documentation' => 'Front Office', 'other' => 'Front Office'
  }.freeze

  # Allowed status transitions (the workflow state machine).
  TRANSITIONS = {
    'created' => %w[assigned cancelled], 'assigned' => %w[accepted escalated],
    'accepted' => %w[in_progress], 'in_progress' => %w[pending_approval resolved],
    'pending_approval' => %w[resolved in_progress], 'resolved' => %w[closed reopened],
    'reopened' => %w[in_progress escalated], 'escalated' => %w[in_progress resolved],
    'closed' => %w[reopened]
  }.freeze

  OPEN_STATUSES = %w[created assigned accepted in_progress pending_approval escalated reopened].freeze

  def validate
    super
    validates_presence [:client_id, :subject]
    validates_includes PRIORITIES, :priority if priority
    validates_includes STATUSES, :status     if status
  end

  def can_transition?(to)
    (TRANSITIONS[status] || []).include?(to)
  end

  def transition!(to)
    return false unless can_transition?(to)
    self.status = to
    self.resolved_at = Time.now if to == 'resolved' && resolved_at.nil?
    if to == 'reopened'
      self.reopen_count = (reopen_count || 0) + 1
      self.resolved_at = nil
    end
    save_changes
    true
  end

  def auto_assign!
    self.assignee = ASSIGNMENT_MAP[category] || 'Front Office'
    self.status = 'assigned' if status == 'created'
    save_changes
  end

  # --- SLA (computed live from due_at) ------------------------------------
  def sla_state
    return 'ok' if %w[resolved closed cancelled].include?(status)
    return 'ok' unless due_at
    now = Time.now
    if now > due_at then 'breached'
    elsif (due_at - now) < 2 * 3600 then 'due_soon'
    else 'ok'
    end
  end

  def sla_remaining
    if %w[resolved closed].include?(status)
      resolved_at && created_at ? "Resolved in #{((resolved_at - created_at) / 3600).round}h" : 'Resolved'
    elsif due_at.nil?
      '—'
    elsif Time.now > due_at
      'Breached'
    else
      secs = (due_at - Time.now).to_i
      "#{secs / 3600}h #{(secs % 3600) / 60}m"
    end
  end

  def as_pos
    {
      id: id, code: code, subject: subject, description: description,
      category: category, priority: priority, status: status, location: location,
      created_by: created_by_name, assignee: assignee, created: created_at,
      due_at: due_at, sla_remaining: sla_remaining, sla_state: sla_state,
      reopen_count: reopen_count || 0, rating: rating,
      # work-order fields (migration 0050)
      assignee_staff_id: assignee_staff_id, completion_note: completion_note,
      accepted_at: accepted_at, rejected_reason: rejected_reason,
      # work-order costs (migration 0064)
      labour_cost: (labour_cost_paise || 0) / 100,
      materials_cost: (materials_cost_paise || 0) / 100,
      total_cost: ((labour_cost_paise || 0) + (materials_cost_paise || 0)) / 100
    }
  end
end
