Sequel.migration do
  change do
    create_table(:plans) do
      primary_key :id
      Integer :client_id, null: false

      String  :name, null: false
      String  :description
      Integer :amount_paise, default: 0
      String  :frequency, default: 'monthly'   # monthly|quarterly|half_yearly|yearly|one_time
      Integer :due_day, default: 1             # day of period the invoice is due

      String  :late_fee_type, default: 'fixed' # fixed|percentage
      Integer :late_fee_value, default: 0      # fixed: paise · percentage: whole percent
      Integer :tax_percent, default: 0         # optional GST/tax %, applied to invoices

      column  :property_types, 'text[]', default: '{}'
      TrueClass :auto_invoice, default: false
      TrueClass :active, default: true

      Integer :created_by
      Integer :updated_by
      DateTime :created_at, default: Sequel::CURRENT_TIMESTAMP
      DateTime :updated_at, default: Sequel::CURRENT_TIMESTAMP

      index [:client_id]
    end
  end
end
