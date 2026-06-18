Sequel.migration do
  change do
    create_table(:documents) do
      primary_key :id
      Integer :client_id, null: false
      String  :code
      String  :name, null: false
      String  :category
      String  :size                  # human size label
      String  :file_key              # S3 object key
      String  :url
      String  :uploaded_by
      Integer :uploaded_by_user_id
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
