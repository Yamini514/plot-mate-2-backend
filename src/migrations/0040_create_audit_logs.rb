Sequel.migration do
  change do
    # Append-only platform audit trail. Written by the single App::Audit.record
    # write path from every state-changing super service (and Session#login).
    create_table(:audit_logs) do
      primary_key :id
      Integer  :actor_id                 # user who acted (super admin or venture user)
      String   :actor_name
      String   :actor_role               # super_admin | admin | ...
      String   :action, null: false      # venture.approve | venture.suspend | user.block | role.change | login | support.access ...
      String   :entity_type              # Client | User | OnboardingRequest | PlatformTicket
      Integer  :entity_id
      Integer  :client_id                # venture context, when applicable
      String   :summary, text: true      # human one-liner
      String   :ip
      String   :user_agent, text: true
      column   :meta, :jsonb, default: '{}'   # before/after, extra context
      DateTime :created_at, default: Sequel::CURRENT_TIMESTAMP
      index :action
      index [:entity_type, :entity_id]
      index :client_id
      index :created_at
    end
  end
end
