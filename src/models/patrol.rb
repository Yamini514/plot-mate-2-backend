class App::Models::Patrol < Sequel::Model
  STATUSES = %w[scheduled in_progress completed].freeze
  one_to_many :patrol_logs, key: :patrol_id, order: :created_at

  def validate
    super
    validates_presence [:client_id]
    validates_includes STATUSES, :status if status
  end

  def as_pos(with_logs: false)
    base = { id: id, code: code, title: title, checkpoints: (checkpoints || []),
             status: status, assigned_to: assigned_to, started_at: started_at,
             completed_at: completed_at, created_at: created_at,
             log_count: patrol_logs_dataset.count }
    base[:logs] = patrol_logs.map(&:as_pos) if with_logs
    base
  end
end
