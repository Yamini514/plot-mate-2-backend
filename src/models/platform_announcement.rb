class App::Models::PlatformAnnouncement < Sequel::Model
  PRIORITIES = %w[low normal high critical].freeze
  AUDIENCES  = %w[all selected].freeze
  STATUSES   = %w[draft scheduled published].freeze

  def validate
    super
    validates_presence [:title]
    validates_includes PRIORITIES, :priority if priority
    validates_includes AUDIENCES,  :audience if audience
    validates_includes STATUSES,   :status   if status
  end

  def as_pos
    { id: id, code: code, title: title, message: message,
      priority: priority || 'normal', audience: audience || 'all',
      client_ids: client_ids || [], status: status || 'draft',
      start_at: start_at, end_at: end_at, published_at: published_at,
      created_at: created_at, updated_at: updated_at }
  end
end
