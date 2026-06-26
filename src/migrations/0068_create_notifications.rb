Sequel.migration do
  change do
    # Per-user in-app notifications (Owner Portal notification center). Targeted
    # (one row per recipient user), written through App::Notify from the events
    # an owner cares about — payment verified, complaint updates, claim/transfer
    # decisions, document expiry.
    create_table(:notifications) do
      primary_key :id
      Integer  :client_id, null: false
      Integer  :user_id, null: false
      String   :kind                       # payment | complaint | claim | transfer | document | notice | project | support
      String   :title, null: false
      String   :body, text: true
      String   :link                       # frontend path to open
      String   :entity_type
      Integer  :entity_id
      DateTime :read_at
      DateTime :created_at, default: Sequel::CURRENT_TIMESTAMP
      index [:user_id, :read_at]
      index :created_at
    end
  end
end
