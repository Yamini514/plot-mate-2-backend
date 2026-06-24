class App::Models::PlatformTicket < Sequel::Model
  one_to_many :messages, class: 'App::Models::PlatformTicketMessage',
                         key: :platform_ticket_id, order: :created_at

  CATEGORIES   = %w[billing technical onboarding abuse feature other].freeze
  PRIORITIES   = %w[low medium high critical].freeze
  STATUSES     = %w[open assigned in_progress waiting_venture resolved closed escalated].freeze
  ESCALATION   = %w[l1 l2 l3].freeze
  OPEN_STATUSES = %w[open assigned in_progress waiting_venture escalated].freeze

  def validate
    super
    validates_presence [:subject]
    validates_includes PRIORITIES, :priority if priority
    validates_includes STATUSES, :status     if status
  end

  def as_pos(with_messages: false)
    base = {
      id: id, code: code, client_id: client_id, raised_by: raised_by,
      raised_by_name: raised_by_name, subject: subject, description: description,
      category: category, priority: priority || 'medium', status: status || 'open',
      assigned_to: assigned_to, escalation_level: escalation_level || 'l1',
      resolved_at: resolved_at, created_at: created_at, updated_at: updated_at
    }
    base[:messages] = messages.map(&:as_pos) if with_messages
    base
  end
end
