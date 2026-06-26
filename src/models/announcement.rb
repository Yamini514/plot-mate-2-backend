class App::Models::Announcement < Sequel::Model
  TYPES = %w[meeting deadline progress general].freeze
  AUDIENCE_TYPES = %w[all phase block owners].freeze
  CHANNELS = %w[in_app email whatsapp].freeze

  def validate
    super
    validates_presence [:client_id, :title]
    validates_includes AUDIENCE_TYPES, :audience_type if audience_type
  end

  def as_pos
    { id: id, code: code, title: title, body: body, author: author,
      date: date, type: type, pinned: pinned,
      # notice targeting + delivery (migration 0053)
      audience_type: audience_type || 'all', audience_values: (audience_values || []),
      attachment_url: attachment_url, attachment_name: attachment_name,
      channels: (channels || []),
      allow_comments: allow_comments.nil? ? true : allow_comments,
      published_at: published_at,
      # scheduled publishing (migration 0065)
      scheduled_at: (respond_to?(:scheduled_at) ? scheduled_at : nil),
      status: (respond_to?(:status) ? (status || 'published') : 'published') }
  end
end
