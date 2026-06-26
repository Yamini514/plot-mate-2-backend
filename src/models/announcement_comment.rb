class App::Models::AnnouncementComment < Sequel::Model
  STATUSES = %w[pending approved hidden].freeze

  def validate
    super
    validates_presence [:client_id, :announcement_id]
    validates_includes STATUSES, :status if status
  end

  def as_pos
    { id: id, announcement_id: announcement_id, author_id: author_id,
      author_name: author_name, body: body, status: status || 'approved',
      created_at: created_at }
  end
end
