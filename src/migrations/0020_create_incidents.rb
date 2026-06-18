Sequel.migration do
  change do
    create_table(:incidents) do
      primary_key :id
      Integer :client_id, null: false
      String  :code                          # INC-3092
      String  :incident_type
      String  :location
      String  :severity, default: 'low'      # low|medium|high|critical
      String  :reported_by
      String  :status, default: 'open'       # open|investigating|escalated|resolved
      DateTime :occurred_at
      Integer :created_by
      Integer :updated_by
      DateTime :created_at, default: Sequel::CURRENT_TIMESTAMP
      DateTime :updated_at, default: Sequel::CURRENT_TIMESTAMP
      index [:client_id, :status]
    end
  end
end
