Sequel.migration do
  change do
    # Preventive / recurring maintenance: a schedule defines a recurring
    # inspection; each time it's performed a log is stored (with a report and,
    # if something's wrong, a raised ticket). next_due_on drives reminders.
    create_table(:maintenance_schedules) do
      primary_key :id
      Integer  :client_id, null: false
      String   :code                     # PM-1001
      String   :title, null: false
      String   :category
      String   :area                     # common area / location
      String   :frequency, default: 'monthly'  # weekly | monthly | quarterly | half_yearly | yearly
      Date     :next_due_on
      Date     :last_done_on
      Integer  :assignee_staff_id
      String   :assignee_name
      String   :notes, text: true
      TrueClass :active, default: true
      Integer  :created_by
      Integer  :updated_by
      DateTime :created_at, default: Sequel::CURRENT_TIMESTAMP
      DateTime :updated_at, default: Sequel::CURRENT_TIMESTAMP
      index [:client_id, :active]
    end

    create_table(:maintenance_logs) do
      primary_key :id
      Integer  :client_id, null: false
      Integer  :schedule_id, null: false
      String   :code                     # PMLOG-1001
      Date     :performed_on
      String   :performed_by
      String   :outcome, default: 'ok'   # ok | issue_found
      String   :report, text: true
      Integer  :ticket_id                # the ticket raised if an issue was found
      Integer  :created_by
      Integer  :updated_by
      DateTime :created_at, default: Sequel::CURRENT_TIMESTAMP
      DateTime :updated_at, default: Sequel::CURRENT_TIMESTAMP
      index :schedule_id
    end
  end
end
