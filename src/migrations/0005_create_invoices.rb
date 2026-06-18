Sequel.migration do
  change do
    create_table(:invoices) do
      primary_key :id
      Integer :client_id, null: false

      String  :number, null: false             # INV-2026-0412
      Integer :plot_id                          # FK -> plots (nullable)
      Integer :plan_id                          # FK -> plans (nullable)

      String  :owner_name
      String  :property                         # "P-047"
      String  :property_type                    # Plot | Apartment | Villa
      String  :plan_name                        # snapshot at issue time
      String  :period                           # "Jun 2026", "FY 2026"

      Integer :amount_paise,   default: 0        # base charge
      Integer :late_fee_paise, default: 0
      Integer :tax_paise,      default: 0
      Integer :discount_paise, default: 0        # sum of waivers/discounts
      Integer :paid_paise,     default: 0
      Integer :balance_paise,  default: 0        # amount + late_fee + tax - discount - paid

      Date    :issued_on
      Date    :due_date
      String  :status, default: 'draft'          # draft|generated|sent|partially_paid|paid|overdue|cancelled
      String  :payment_method                    # last payment method (exposed as "method")

      Integer :created_by
      Integer :updated_by
      DateTime :created_at, default: Sequel::CURRENT_TIMESTAMP
      DateTime :updated_at, default: Sequel::CURRENT_TIMESTAMP

      index [:client_id, :number], unique: true
      index [:client_id, :status]
      index [:plot_id]
    end
  end
end
