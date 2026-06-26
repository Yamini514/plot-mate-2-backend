class App::Models::ComplaintEvent < Sequel::Model
  # Append-only timeline entry for a complaint (internal note or a recorded
  # status/assignment/escalation change). Written via Complaints#log_event.
  KINDS = %w[note status assignment escalation confirmation reopen attachment].freeze

  def as_pos
    { id: id, kind: kind, body: body, internal: internal,
      actor_name: actor_name, actor_id: actor_id, meta: meta || {},
      created_at: created_at }
  end
end
