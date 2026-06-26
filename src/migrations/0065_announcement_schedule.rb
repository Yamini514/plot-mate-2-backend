Sequel.migration do
  change do
    # Scheduled publishing for notices: a notice can be drafted/scheduled and
    # goes live when App::Scheduler reaches its scheduled_at.
    alter_table(:announcements) do
      add_column :scheduled_at, DateTime
      add_column :status, String, default: 'published'   # draft | scheduled | published
      add_index :status
    end
  end
end
