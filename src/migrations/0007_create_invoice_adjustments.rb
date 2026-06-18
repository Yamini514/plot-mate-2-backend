Sequel.migration do
  change do
    # Waivers / discounts / credits applied to an invoice — kept as an
    # auditable log so every reduction in balance has a reason and an author.
    create_table(:invoice_adjustments) do
      primary_key :id
      Integer :client_id, null: false
      Integer :invoice_id, null: false

      String  :kind, default: 'waiver'   # waiver | discount | credit
      Integer :amount_paise, default: 0  # positive value that reduces balance
      String  :reason

      Integer :created_by
      Integer :updated_by
      DateTime :created_at, default: Sequel::CURRENT_TIMESTAMP
      DateTime :updated_at, default: Sequel::CURRENT_TIMESTAMP

      index [:invoice_id]
    end
  end
end
