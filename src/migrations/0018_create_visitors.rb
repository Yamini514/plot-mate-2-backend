Sequel.migration do
  change do
    create_table(:visitors) do
      primary_key :id
      Integer :client_id, null: false
      String  :code                          # VIS-2418
      String  :name, null: false
      String  :phone
      String  :resident_name
      String  :plot_no
      String  :purpose
      String  :vehicle_no
      DateTime :check_in
      DateTime :check_out
      String  :status, default: 'pending'    # pending|approved|inside|checked_out|rejected|expected|left
      Integer :created_by
      Integer :updated_by
      DateTime :created_at, default: Sequel::CURRENT_TIMESTAMP
      DateTime :updated_at, default: Sequel::CURRENT_TIMESTAMP
      index [:client_id, :status]
    end
  end
end
