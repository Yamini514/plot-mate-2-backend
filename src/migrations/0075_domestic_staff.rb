Sequel.migration do
  change do
    # Domestic workers registered against a plot (maid/driver/cook/…). The gate
    # logs their daily entry/exit as attendance.
    create_table(:domestic_workers) do
      primary_key :id
      Integer  :client_id, null: false
      String   :code                       # DW-1001
      String   :name, null: false
      String   :worker_type                # Maid | Driver | … (from settings.lists)
      String   :phone
      String   :plot_no
      String   :photo_url, text: true
      TrueClass :active, default: true
      Integer  :created_by
      DateTime :created_at, default: Sequel::CURRENT_TIMESTAMP
      DateTime :updated_at, default: Sequel::CURRENT_TIMESTAMP
      index [:client_id, :active]
    end

    # Attendance: one row per entry, stamped out on exit.
    create_table(:domestic_attendance) do
      primary_key :id
      Integer  :client_id, null: false
      Integer  :worker_id, null: false
      DateTime :entry_at
      DateTime :exit_at
      Integer  :created_by
      DateTime :created_at, default: Sequel::CURRENT_TIMESTAMP
      index [:worker_id, :created_at]
    end
  end
end
