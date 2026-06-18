class App::Models::Announcement < Sequel::Model
  TYPES = %w[meeting deadline progress general].freeze

  def validate
    super
    validates_presence [:client_id, :title]
  end

  def as_pos
    { id: id, code: code, title: title, body: body, author: author,
      date: date, type: type, pinned: pinned }
  end
end
