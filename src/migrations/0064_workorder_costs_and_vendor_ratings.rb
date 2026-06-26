Sequel.migration do
  change do
    # Work-order cost capture: labour + a cached materials total on the ticket.
    alter_table(:tickets) do
      add_column :labour_cost_paise, Integer, default: 0
      add_column :materials_cost_paise, Integer, default: 0
    end

    # Itemised materials used on a work order.
    create_table(:work_order_materials) do
      primary_key :id
      Integer  :ticket_id, null: false
      Integer  :client_id, null: false
      String   :item, null: false
      Integer  :quantity, default: 1
      Integer  :unit_cost_paise, default: 0
      Integer  :created_by
      DateTime :created_at, default: Sequel::CURRENT_TIMESTAMP
      index :ticket_id
    end

    # Vendor ratings (1–5) — the source for derived performance metrics.
    create_table(:vendor_ratings) do
      primary_key :id
      Integer  :client_id, null: false
      Integer  :staff_id, null: false
      Integer  :ticket_id
      Integer  :score, null: false
      String   :note, text: true
      Integer  :rated_by
      DateTime :created_at, default: Sequel::CURRENT_TIMESTAMP
      index :staff_id
    end
  end
end
