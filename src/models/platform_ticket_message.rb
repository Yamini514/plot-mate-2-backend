class App::Models::PlatformTicketMessage < Sequel::Model
  many_to_one :platform_ticket, key: :platform_ticket_id

  def validate
    super
    validates_presence [:platform_ticket_id, :body]
  end

  def as_pos
    { id: id, author_id: author_id, author_name: author_name,
      author_role: author_role, body: body, internal: !!internal,
      created_at: created_at }
  end
end
