Sequel.migration do
  change do
    create_table(:photos) do
      primary_key :id
      Integer :client_id, null: false
      String  :code
      String  :url
      String  :file_key
      String  :caption
      String  :category
      Date    :date
      TrueClass :active, default: true
      Integer :created_by
      Integer :updated_by
      DateTime :created_at, default: Sequel::CURRENT_TIMESTAMP
      DateTime :updated_at, default: Sequel::CURRENT_TIMESTAMP
      index [:client_id]
    end
  end
end
