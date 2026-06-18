Sequel.migration do
  change do
    create_table(:users) do
      primary_key :id

      Integer :client_id, null: false

      String  :full_name
      String  :email, size: 150
      String  :encoded_password, size: 200

      Integer :role # 0=member, 1=guard, 2=admin
      String  :phone_number

      String  :device_uuid
      String  :current_session_id, text: true

      String   :reset_token
      DateTime :reset_sent_at

      jsonb :extras, default: '{}' # title, plot_no, guard_id, etc.

      DateTime :last_logged_in_at
      TrueClass :active, default: true

      Integer :created_by
      Integer :updated_by
      DateTime :created_at, default: Sequel::CURRENT_TIMESTAMP
      DateTime :updated_at, default: Sequel::CURRENT_TIMESTAMP

      index [:client_id]
      index [:email]
    end
  end
end
