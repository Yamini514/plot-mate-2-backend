Sequel.migration do
  change do
    create_table(:payments) do
      primary_key :id
      Integer :client_id, null: false

      String  :number                           # PMT-1042
      String  :receipt_number                   # RCPT-2026-0001
      Integer :invoice_id                        # FK -> invoices (nullable for ad-hoc)
      Integer :plot_id

      String  :owner_name
      String  :property
      Integer :amount_paise, default: 0
      String  :mode, default: 'cash'             # upi|bank|cash|card|net_banking
      String  :reference                         # UTR / txn ref
      String  :provider, default: 'manual'       # manual|stripe
      String  :provider_ref                      # stripe payment_intent id (idempotency)
      Date    :paid_on
      String  :fy                                # "2024-25"
      String  :note

      Integer :created_by
      Integer :updated_by
      DateTime :created_at, default: Sequel::CURRENT_TIMESTAMP
      DateTime :updated_at, default: Sequel::CURRENT_TIMESTAMP

      index [:client_id]
      index [:invoice_id]
      index [:provider_ref]
    end
  end
end
