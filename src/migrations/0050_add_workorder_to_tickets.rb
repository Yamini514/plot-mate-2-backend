Sequel.migration do
  change do
    # Work-order completion: link the assigned vendor, capture the completion
    # report, and record vendor accept/reject so a ticket carries its full
    # field history (not just a status).
    alter_table(:tickets) do
      add_column :assignee_staff_id, Integer   # the vendor/staff row handling it
      add_column :completion_note, String, text: true
      add_column :accepted_at, DateTime        # vendor accepted the assignment
      add_column :rejected_reason, String, text: true
    end
  end
end
