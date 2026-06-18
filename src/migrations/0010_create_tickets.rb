Sequel.migration do
  change do
    create_table(:tickets) do
      primary_key :id
      Integer :client_id, null: false

      String  :code                        # TKT-4821
      String  :subject, null: false
      String  :description
      String  :category                    # maintenance | plumbing | ...
      String  :priority, default: 'medium'  # low | medium | high | critical
      String  :status,   default: 'created' # workflow state (see Ticket::STATUSES)
      String  :location

      String  :created_by_name             # "Naveen Varma (Owner)"
      Integer :created_by_user_id
      String  :assignee

      DateTime :due_at                     # SLA deadline (set from priority at creation)
      DateTime :resolved_at
      Integer  :reopen_count, default: 0
      Integer  :rating

      Integer :created_by
      Integer :updated_by
      DateTime :created_at, default: Sequel::CURRENT_TIMESTAMP
      DateTime :updated_at, default: Sequel::CURRENT_TIMESTAMP

      index [:client_id, :status]
      index [:client_id, :category]
      index [:created_by_user_id]
    end
  end
end
