Sequel.migration do
  change do
    create_table(:plots) do
      primary_key :id

      Integer :client_id, null: false

      String  :plot_no, null: false           # "P-047"
      String  :owner_name                      # nullable — unregistered plots
      String  :phone
      String  :email
      Integer :size_sqyd
      String  :phase                           # "Phase 1" / "Phase 2" / "Phase 3"

      String  :membership, default: 'unverified'   # verified | unverified
      String  :payment_status, default: 'unknown'  # paid | pending | unknown

      Integer :amount_due_paise, default: 0    # canonical money unit (paise)
      Date    :last_payment_date
      Integer :days_overdue, default: 0        # denormalized; billing will own this later

      TrueClass :active, default: true

      Integer :created_by
      Integer :updated_by
      DateTime :created_at, default: Sequel::CURRENT_TIMESTAMP
      DateTime :updated_at, default: Sequel::CURRENT_TIMESTAMP

      index [:client_id, :plot_no], unique: true
      index [:client_id, :payment_status]
    end
  end
end
