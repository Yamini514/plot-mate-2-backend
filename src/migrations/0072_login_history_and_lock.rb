Sequel.migration do
  change do
    # Per-user login history (RBAC user management → "View login history").
    create_table(:login_events) do
      primary_key :id
      Integer  :user_id, null: false
      Integer  :client_id
      String   :ip
      String   :user_agent, text: true
      TrueClass :success, default: true
      DateTime :created_at, default: Sequel::CURRENT_TIMESTAMP
      index [:user_id, :created_at]
    end

    # Explicit account lock (distinct from `active`/blocked): a hard lock an admin
    # sets, separate from deactivation.
    alter_table(:users) do
      add_column :locked_at, DateTime
      add_column :lock_reason, String, text: true
    end
  end
end
