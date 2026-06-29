Sequel.migration do
  change do
    # Gate vehicle register: entry/exit of owner & visitor vehicles, with optional
    # parking assignment. Vehicle types come from venture config (settings.lists).
    create_table(:vehicle_logs) do
      primary_key :id
      Integer  :client_id, null: false
      String   :code                       # VEH-1001
      String   :vehicle_no, null: false
      String   :vehicle_type               # Car | Bike | Commercial | Emergency | …
      String   :owner_kind, default: 'visitor'  # owner | visitor
      String   :plot_no
      String   :driver_name
      String   :phone
      String   :parking_slot
      String   :status, default: 'inside'  # inside | exited
      DateTime :entry_at
      DateTime :exit_at
      Integer  :created_by
      DateTime :created_at, default: Sequel::CURRENT_TIMESTAMP
      DateTime :updated_at, default: Sequel::CURRENT_TIMESTAMP
      index [:client_id, :status]
      index :vehicle_no
    end
  end
end
