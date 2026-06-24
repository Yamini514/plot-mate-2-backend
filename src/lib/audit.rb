module App
  # Single write path for the platform audit trail (audit_logs). Call from every
  # state-changing super-admin action and from Session#login. Never raises — an
  # audit-write failure must not break the action it records (it's logged and
  # swallowed). Actor + IP are captured from the current request context.
  #
  #   App::Audit.record('venture.suspend', entity: client, summary: "Suspended Green City",
  #                     client_id: client.id, meta: { reason: reason })
  module Audit
    module_function

    def record(action, entity: nil, entity_type: nil, entity_id: nil,
               client_id: nil, summary: nil, meta: {}, actor: nil)
      actor ||= safe_actor
      etype = entity_type || (entity && entity.class.name.split('::').last)
      eid   = entity_id   || (entity.respond_to?(:id) ? entity.id : nil)

      App::Models::AuditLog.create(
        actor_id:   actor&.id,
        actor_name: actor&.full_name,
        actor_role: actor&.role_name,
        action:     action.to_s,
        entity_type: etype,
        entity_id:   eid,
        client_id:   client_id,
        summary:     summary,
        ip:          (App.cu.ip rescue nil),
        meta:        meta || {}
      )
    rescue => e
      App.logger.error("Audit.record(#{action}) failed: #{e.class}: #{e.message}")
      nil
    end

    def safe_actor
      App.cu.user_obj
    rescue
      nil
    end
  end
end
