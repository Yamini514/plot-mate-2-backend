Sequel.migration do
  change do
    # Treasury ledger. Every collected payment posts an income entry here so
    # the books reconcile with billing. Expenses will write debit entries too.
    create_table(:transactions) do
      primary_key :id
      Integer :client_id, null: false

      String  :direction, default: 'credit'  # credit (income) | debit (expense)
      String  :category, default: 'maintenance'
      Integer :amount_paise, default: 0

      Integer :payment_id    # source payment (for income)
      Integer :invoice_id
      String  :reference
      String  :note
      Date    :occurred_on

      Integer :created_by
      Integer :updated_by
      DateTime :created_at, default: Sequel::CURRENT_TIMESTAMP
      DateTime :updated_at, default: Sequel::CURRENT_TIMESTAMP

      index [:client_id, :direction]
      index [:payment_id]
    end
  end
end
