Sequel.migration do
  change do
    create_table(:amenities) do
      primary_key :id
      Integer :client_id, null: false
      String  :code
      String  :name, null: false
      String  :description
      Integer :capacity
      Integer :hourly_rate_paise, default: 0
      String  :icon
      String  :status, default: 'available'  # available|maintenance
      TrueClass :active, default: true
      Integer :created_by
      Integer :updated_by
      DateTime :created_at, default: Sequel::CURRENT_TIMESTAMP
      DateTime :updated_at, default: Sequel::CURRENT_TIMESTAMP
      index [:client_id]
    end
  end
end
