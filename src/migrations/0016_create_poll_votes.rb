Sequel.migration do
  change do
    # One row per (poll, user) — enforces single-vote integrity.
    create_table(:poll_votes) do
      primary_key :id
      Integer :client_id, null: false
      Integer :poll_id, null: false
      Integer :user_id, null: false
      String  :option_id
      DateTime :created_at, default: Sequel::CURRENT_TIMESTAMP
      index [:poll_id, :user_id], unique: true
    end
  end
end
