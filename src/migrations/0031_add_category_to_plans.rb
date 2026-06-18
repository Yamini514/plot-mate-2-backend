Sequel.migration do
  change do
    # Classify each charge so the catalog can model more than maintenance:
    # corpus/sinking funds, transfer & NOC fees, penalties, water, amenities, etc.
    # Existing rows default to 'maintenance' (backward-compatible).
    alter_table(:plans) do
      add_column :category, String, default: 'maintenance', null: false
    end

    # Snapshot the category onto the invoice at issue time, so slips and
    # filters keep working even if the plan is later re-categorised or deleted.
    alter_table(:invoices) do
      add_column :category, String, default: 'maintenance'
    end
  end
end
