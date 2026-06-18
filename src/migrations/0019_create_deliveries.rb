Sequel.migration do
  change do
    create_table(:deliveries) do
      primary_key :id
      Integer :client_id, null: false
      String  :code                          # PKG-7741
      String  :courier
      String  :agent
      String  :resident_name
      String  :plot_no
      DateTime :received_at
      DateTime :delivered_at
      String  :status, default: 'waiting'    # received|waiting|delivered
      Integer :created_by
      Integer :updated_by
      DateTime :created_at, default: Sequel::CURRENT_TIMESTAMP
      DateTime :updated_at, default: Sequel::CURRENT_TIMESTAMP
      index [:client_id, :status]
    end
  end
end
