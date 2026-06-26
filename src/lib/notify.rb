module App
  # Single write path for in-app notifications (notifications table). Targeted
  # at one recipient user. Never raises — a notify failure must not break the
  # action that triggered it (logged + swallowed), mirroring App::Audit.
  #
  #   App::Notify.create(user_id: owner.id, client_id: cid, kind: 'payment',
  #                      title: 'Payment verified', body: '...', link: '/member/billing',
  #                      entity: payment)
  module Notify
    module_function

    def create(user_id:, client_id:, kind:, title:, body: nil, link: nil,
               entity: nil, entity_type: nil, entity_id: nil)
      return nil if user_id.nil?
      App::Models::Notification.create(
        user_id: user_id, client_id: client_id, kind: kind.to_s, title: title,
        body: body, link: link,
        entity_type: entity_type || (entity && entity.class.name.split('::').last),
        entity_id: entity_id || (entity.respond_to?(:id) ? entity.id : nil)
      )
    rescue => e
      App.logger.error("Notify.create(#{kind}) failed: #{e.class}: #{e.message}")
      nil
    end
  end
end
