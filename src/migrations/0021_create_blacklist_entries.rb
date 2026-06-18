Sequel.migration do
  change do
    # Unified blacklist for both barred visitors and vehicles.
    create_table(:blacklist_entries) do
      primary_key :id
      Integer :client_id, null: false
      String  :code                          # BL-V-21 / BL-C-14
      String  :kind, default: 'visitor'      # visitor | vehicle
      String  :name
      String  :phone
      String  :plate
      String  :model
      String  :reason
      String  :added_by
      Integer :attempts, default: 0
      String  :status, default: 'blacklisted' # blacklisted | flagged
      Integer :created_by
      Integer :updated_by
      DateTime :created_at, default: Sequel::CURRENT_TIMESTAMP
      DateTime :updated_at, default: Sequel::CURRENT_TIMESTAMP
      index [:client_id, :kind]
    end
  end
end
