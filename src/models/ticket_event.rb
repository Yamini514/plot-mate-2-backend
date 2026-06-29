class App::Models::TicketEvent < Sequel::Model
  # Append-only work-order timeline entry (status change, comment, material, visit).
  def as_pos
    { id: id, kind: kind, body: body, internal: internal,
      actor_name: actor_name, actor_id: actor_id, meta: meta || {},
      created_at: created_at }
  end
end
