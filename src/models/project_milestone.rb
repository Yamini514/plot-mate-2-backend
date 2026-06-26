class App::Models::ProjectMilestone < Sequel::Model
  STATUSES = %w[pending done].freeze

  def validate
    super
    validates_presence [:client_id, :project_id, :title]
  end

  # Overdue when a pending milestone's due date has passed.
  def state
    return 'done' if status == 'done'
    return 'overdue' if due_on && due_on < Date.today
    'pending'
  end

  def as_pos
    { id: id, project_id: project_id, title: title, due_on: due_on,
      status: status || 'pending', done_on: done_on, sort_order: sort_order || 0,
      state: state }
  end
end
