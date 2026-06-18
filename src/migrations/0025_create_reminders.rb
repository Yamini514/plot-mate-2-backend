Sequel.migration do
  change do
    create_table(:reminders) do
      primary_key :id
      Integer :client_id, null: false
      String  :code
      Integer :plot_id
      String  :plot_no
      String  :owner_name
      Integer :amount_paise, default: 0
      String  :channel, default: 'whatsapp'  # whatsapp | sms | email
      DateTime :scheduled_for
      String  :status, default: 'scheduled'  # scheduled | sent | responded
      Integer :created_by
      Integer :updated_by
      DateTime :created_at, default: Sequel::CURRENT_TIMESTAMP
      DateTime :updated_at, default: Sequel::CURRENT_TIMESTAMP
      index [:client_id, :status]
    end
  end
end
