Sequel.migration do
  change do
    # Deepen complaints to a full workflow: escalation, resolution/closure
    # stamps, reopen counter, resident sign-off, and inline attachments.
    alter_table(:complaints) do
      add_column :escalated_at, DateTime
      add_column :escalation_level, String              # l1 | l2 | l3
      add_column :resolved_at, DateTime
      add_column :closed_at, DateTime
      add_column :reopen_count, Integer, default: 0
      add_column :resident_confirmed, TrueClass          # resident signed off on the fix
      add_column :resident_confirmed_at, DateTime
      add_column :attachments, :jsonb, default: '[]'     # [{name,url,key,size}]
    end

    # Append-only complaint timeline: internal notes + every status/assignment
    # /escalation change, with the acting user captured.
    create_table(:complaint_events) do
      primary_key :id
      Integer  :complaint_id, null: false
      Integer  :client_id, null: false
      String   :kind                                     # note | status | assignment | escalation | confirmation | reopen
      String   :body, text: true
      TrueClass :internal, default: true                 # internal note vs resident-visible
      String   :actor_name
      Integer  :actor_id
      column   :meta, :jsonb, default: '{}'              # { from:, to: } for transitions
      DateTime :created_at, default: Sequel::CURRENT_TIMESTAMP
      index :complaint_id
    end
  end
end
