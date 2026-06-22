class App::Models::Incident < Sequel::Model
  SEVERITIES = %w[low medium high critical].freeze
  STATUSES   = %w[open investigating escalated resolved].freeze

  def validate
    super
    validates_presence [:client_id, :incident_type]
    validates_includes SEVERITIES, :severity if severity
    validates_includes STATUSES, :status     if status
  end

  def as_pos
    { id: id, code: code, type: incident_type, location: location, severity: severity,
      # `description` is guarded so the model still serializes cleanly before
      # the 0035 migration adds the column.
      description: (respond_to?(:description) ? description : nil),
      reported_by: reported_by, status: status, occurred_at: occurred_at, created_at: created_at }
  end
end
