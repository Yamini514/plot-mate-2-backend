Sequel.migration do
  change do
    create_table(:polls) do
      primary_key :id
      Integer :client_id, null: false
      String  :code
      String  :question, null: false
      String  :description
      jsonb   :options, default: '[]'      # [{id,label,votes}]
      String  :status, default: 'active'   # active|closed
      Date    :closes_at
      Integer :total_voters, default: 0
      Integer :created_by
      Integer :updated_by
      DateTime :created_at, default: Sequel::CURRENT_TIMESTAMP
      DateTime :updated_at, default: Sequel::CURRENT_TIMESTAMP
      index [:client_id]
    end
  end
end
