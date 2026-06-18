Sequel.migration do
  change do
    create_table(:bookings) do
      primary_key :id
      Integer :client_id, null: false
      String  :code
      Integer :amenity_id
      String  :amenity_name
      String  :booked_by
      Integer :booked_by_user_id
      String  :plot_no
      Date    :date
      String  :slot
      String  :status, default: 'pending'   # pending|confirmed|cancelled
      Integer :amount_paise, default: 0
      Integer :created_by
      Integer :updated_by
      DateTime :created_at, default: Sequel::CURRENT_TIMESTAMP
      DateTime :updated_at, default: Sequel::CURRENT_TIMESTAMP
      index [:client_id, :status]
      index [:booked_by_user_id]
    end
  end
end
