Sequel.migration do
  change do
    create_table(:announcements) do
      primary_key :id
      Integer :client_id, null: false
      String  :code
      String  :title, null: false
      String  :body
      String  :author
      Date    :date
      String  :type, default: 'general'   # meeting|deadline|progress|general
      TrueClass :pinned, default: false
      TrueClass :active, default: true
      Integer :created_by
      Integer :updated_by
      DateTime :created_at, default: Sequel::CURRENT_TIMESTAMP
      DateTime :updated_at, default: Sequel::CURRENT_TIMESTAMP
      index [:client_id]
    end
  end
end
