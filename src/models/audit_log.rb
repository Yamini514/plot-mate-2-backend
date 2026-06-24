class App::Models::AuditLog < Sequel::Model
  # Append-only. Never updated or deleted in normal operation — write through
  # App::Audit.record so actor/ip capture stays consistent.
  def as_pos
    { id: id, actor_id: actor_id, actor_name: actor_name, actor_role: actor_role,
      action: action, entity_type: entity_type, entity_id: entity_id,
      client_id: client_id, summary: summary, ip: ip, meta: meta || {},
      created_at: created_at }
  end
end
