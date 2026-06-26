Sequel.migration do
  change do
    # Payment verification (offline self-reported payments wait for admin
    # approval before they hit the books) + bank reconciliation flags.
    alter_table(:payments) do
      add_column :verification_status, String, default: 'verified'  # pending | verified | rejected
      add_column :verified_by, Integer
      add_column :verified_at, DateTime
      add_column :reject_reason, String, text: true
      add_column :submitted_by_user_id, Integer       # member who self-reported it
      add_column :reconciled, TrueClass, default: false
      add_column :reconciled_at, DateTime
      add_column :bank_ref, String                     # bank statement reference matched
      add_index :verification_status
    end

    # Recurring interest on overdue balances (separate from the one-shot late fee).
    alter_table(:invoices) do
      add_column :interest_paise, Integer, default: 0
      add_column :interest_accrued_on, Date            # last month interest was added
    end

    # Refunds / credit reversals against a recorded payment.
    create_table(:refunds) do
      primary_key :id
      Integer  :client_id, null: false
      Integer  :payment_id, null: false
      Integer  :plot_id
      String   :code                                   # REF-2026-0001
      Integer  :amount_paise, null: false
      String   :reason, text: true
      String   :method, default: 'bank'                # upi | bank | cash | adjustment
      String   :status, default: 'pending'             # pending | approved | rejected | paid
      Integer  :approved_by
      DateTime :approved_at
      Integer  :created_by
      Integer  :updated_by
      DateTime :created_at, default: Sequel::CURRENT_TIMESTAMP
      DateTime :updated_at, default: Sequel::CURRENT_TIMESTAMP
      index :payment_id
      index [:client_id, :status]
    end
  end
end
