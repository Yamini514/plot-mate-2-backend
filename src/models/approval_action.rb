class App::Models::ApprovalAction < Sequel::Model
  many_to_one :approval_request, key: :approval_request_id

  def validate
    super
    validates_presence [:approval_request_id, :action]
  end

  def as_pos
    { id: id, actor_id: actor_id, actor_name: actor_name, actor_role: actor_role,
      action: action, note: note, meta: meta || {}, created_at: created_at }
  end
end
