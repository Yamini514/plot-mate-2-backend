class App::Models::AnnouncementReaction < Sequel::Model
  KINDS = %w[like celebrate concerned].freeze

  def validate
    super
    validates_presence [:client_id, :announcement_id]
  end

  def as_pos
    { id: id, user_id: user_id, kind: kind || 'like', created_at: created_at }
  end
end
