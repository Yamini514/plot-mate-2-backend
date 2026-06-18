Sequel.migration do
  change do
    # One row per (event, user) — RSVP is a toggle, never double-counted.
    create_table(:event_rsvps) do
      primary_key :id
      Integer :client_id, null: false
      Integer :event_id, null: false
      Integer :user_id, null: false
      DateTime :created_at, default: Sequel::CURRENT_TIMESTAMP
      index [:event_id, :user_id], unique: true
    end
  end
end
