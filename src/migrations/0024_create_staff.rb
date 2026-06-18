Sequel.migration do
  change do
    create_table(:staff) do
      primary_key :id
      Integer :client_id, null: false
      String  :code
      String  :name, null: false
      String  :role
      String  :phone
      Integer :monthly_salary_paise, default: 0
      Date    :joined_on
      String  :status, default: 'active'   # active | on_leave | inactive
      String  :kind, default: 'staff'      # staff | vendor
      TrueClass :active, default: true
      Integer :created_by
      Integer :updated_by
      DateTime :created_at, default: Sequel::CURRENT_TIMESTAMP
      DateTime :updated_at, default: Sequel::CURRENT_TIMESTAMP
      index [:client_id, :kind]
    end
  end
end
