class App::Models::MaintenanceLog < Sequel::Model
  many_to_one :maintenance_schedule, key: :schedule_id

  OUTCOMES = %w[ok issue_found].freeze

  def validate
    super
    validates_presence [:client_id, :schedule_id]
    validates_includes OUTCOMES, :outcome if outcome
  end

  def as_pos
    { id: id, code: code, schedule_id: schedule_id, performed_on: performed_on,
      performed_by: performed_by, outcome: outcome || 'ok', report: report,
      ticket_id: ticket_id, created_at: created_at }
  end
end
