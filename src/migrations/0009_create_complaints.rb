Sequel.migration do
  change do
    create_table(:complaints) do
      primary_key :id
      Integer :client_id, null: false

      String  :code                       # CMP-051
      String  :title, null: false
      String  :description
      String  :category                   # Electricity | Water | Roads | ...
      String  :priority, default: 'medium' # low | medium | high
      String  :status, default: 'open'     # open | in_progress | resolved | closed

      String  :raised_by                   # display name
      Integer :raised_by_user_id
      String  :plot_no
      String  :assigned_to

      Integer :created_by
      Integer :updated_by
      DateTime :created_at, default: Sequel::CURRENT_TIMESTAMP
      DateTime :updated_at, default: Sequel::CURRENT_TIMESTAMP

      index [:client_id, :status]
      index [:raised_by_user_id]
    end
  end
end
