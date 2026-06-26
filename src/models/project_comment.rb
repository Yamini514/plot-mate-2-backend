class App::Models::ProjectComment < Sequel::Model
  STATUSES = %w[pending approved hidden].freeze

  def validate
    super
    validates_presence [:client_id, :project_id]
  end

  def as_pos
    { id: id, project_id: project_id, author_id: author_id, author_name: author_name,
      body: body, status: status || 'approved', created_at: created_at }
  end
end
