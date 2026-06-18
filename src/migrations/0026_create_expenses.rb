Sequel.migration do
  change do
    create_table(:expenses) do
      primary_key :id
      Integer :client_id, null: false
      String  :code
      Date    :date
      String  :description
      String  :category
      String  :vendor
      Integer :amount_paise, default: 0
      String  :notes
      Integer :created_by
      Integer :updated_by
      DateTime :created_at, default: Sequel::CURRENT_TIMESTAMP
      DateTime :updated_at, default: Sequel::CURRENT_TIMESTAMP
      index [:client_id]
    end
  end
end
