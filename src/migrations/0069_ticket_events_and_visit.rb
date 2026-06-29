Sequel.migration do
  change do
    # Work-order timeline + vendor↔admin comment thread (mirrors complaint_events).
    create_table(:ticket_events) do
      primary_key :id
      Integer  :ticket_id, null: false
      Integer  :client_id, null: false
      String   :kind                    # note | status | material | visit | assignment | photo
      String   :body, text: true
      TrueClass :internal, default: true # vendor/admin only vs resident-visible
      String   :actor_name
      Integer  :actor_id
      column   :meta, :jsonb, default: '{}'
      DateTime :created_at, default: Sequel::CURRENT_TIMESTAMP
      index :ticket_id
    end

    # Scheduled site-visit date the vendor commits to.
    alter_table(:tickets) do
      add_column :scheduled_visit_at, DateTime
    end
  end
end
