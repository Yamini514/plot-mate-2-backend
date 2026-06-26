Sequel.migration do
  change do
    # Idempotency stamps so the background scheduler (App::Scheduler, run via
    # `rake scheduler:run` on a cron) can dispatch each reminder exactly once and
    # not re-nag on every tick.
    alter_table(:reminders) do
      add_column :sent_at, DateTime          # when the scheduler/admin actually dispatched it
    end

    alter_table(:documents) do
      add_column :expiry_reminded_at, DateTime  # last time an expiry reminder went out
    end

    alter_table(:maintenance_schedules) do
      add_column :reminded_at, DateTime         # last time a due reminder went out
    end
  end
end
