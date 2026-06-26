class App::Models::ProjectUpdate < Sequel::Model
  many_to_one :project, key: :project_id

  def validate
    super
    validates_presence [:client_id, :project_id]
  end

  def as_pos
    { id: id, project_id: project_id, title: title, note: note,
      percent: percent, spent: (spent_paise || 0) / 100, is_delay: !!is_delay,
      author_name: author_name, created_at: created_at }
  end
end
