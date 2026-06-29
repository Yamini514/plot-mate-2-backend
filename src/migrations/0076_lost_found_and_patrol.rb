Sequel.migration do
  change do
    # Lost & found register.
    create_table(:lost_found_items) do
      primary_key :id
      Integer  :client_id, null: false
      String   :code                       # LF-1001
      String   :title, null: false
      String   :description, text: true
      String   :photo_url, text: true
      String   :found_location
      String   :status, default: 'open'    # open | claimed | closed
      String   :claimant_name
      String   :claimant_phone
      Integer  :created_by
      DateTime :created_at, default: Sequel::CURRENT_TIMESTAMP
      DateTime :updated_at, default: Sequel::CURRENT_TIMESTAMP
      index [:client_id, :status]
    end

    # Security patrol schedules + checkpoint scans.
    create_table(:patrols) do
      primary_key :id
      Integer  :client_id, null: false
      String   :code                       # PAT-1001
      String   :title
      column   :checkpoints, :jsonb, default: '[]'  # ["Gate A","Block 1",…]
      String   :status, default: 'scheduled'        # scheduled | in_progress | completed
      Integer  :assigned_to                # guard user id
      DateTime :started_at
      DateTime :completed_at
      Integer  :created_by
      DateTime :created_at, default: Sequel::CURRENT_TIMESTAMP
      DateTime :updated_at, default: Sequel::CURRENT_TIMESTAMP
      index [:client_id, :status]
    end

    # Each checkpoint scan / observation during a patrol.
    create_table(:patrol_logs) do
      primary_key :id
      Integer  :patrol_id, null: false
      Integer  :client_id, null: false
      String   :checkpoint
      String   :note, text: true
      String   :photo_url, text: true
      TrueClass :issue, default: false     # an issue was reported here
      Integer  :created_by
      DateTime :created_at, default: Sequel::CURRENT_TIMESTAMP
      index :patrol_id
    end
  end
end
