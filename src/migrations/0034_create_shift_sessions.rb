Sequel.migration do
  change do
    # One row per guard "shift" — opened when a guard signs in and closed when
    # they sign out (or end their shift). Powers the admin attendance view and
    # the early-clock-out confirmation on the guard side.
    create_table(:shift_sessions) do
      primary_key :id

      Integer :client_id, null: false
      Integer :user_id,   null: false

      String   :shift_name           # Morning / Evening / Night (derived at sign-in)
      DateTime :started_at           # sign-in / clock-in time
      DateTime :ended_at             # sign-out / clock-out time (nil = on duty now)
      DateTime :scheduled_end        # expected end of the shift (for early-out detection)
      TrueClass :ended_early, default: false
      String   :end_reason           # logout | shift_end | superseded

      Integer  :created_by
      Integer  :updated_by
      DateTime :created_at, default: Sequel::CURRENT_TIMESTAMP
      DateTime :updated_at, default: Sequel::CURRENT_TIMESTAMP

      index [:client_id]
      index [:user_id]
      index [:ended_at]
    end
  end
end
