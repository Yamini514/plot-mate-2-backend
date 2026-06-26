class App::Models::Notification < Sequel::Model
  def as_pos
    { id: id, kind: kind, title: title, body: body, link: link,
      entity_type: entity_type, entity_id: entity_id,
      read: !read_at.nil?, read_at: read_at, created_at: created_at }
  end
end
