Sequel.migration do
  change do
    create_table(:events) do
      primary_key :id
      Integer :client_id, null: false
      String  :code
      String  :title, null: false
      String  :description
      Date    :date
      String  :time
      String  :location
      String  :type, default: 'social'   # meeting|maintenance|social
      Integer :rsvp_count, default: 0
      TrueClass :active, default: true
      Integer :created_by
      Integer :updated_by
      DateTime :created_at, default: Sequel::CURRENT_TIMESTAMP
      DateTime :updated_at, default: Sequel::CURRENT_TIMESTAMP
      index [:client_id]
    end
  end
end
