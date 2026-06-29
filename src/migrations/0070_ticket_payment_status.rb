Sequel.migration do
  change do
    # Vendor payment tracking on completed work orders (admin-set; read-only to
    # the vendor). No payout/accounting subsystem — just a status the vendor sees.
    alter_table(:tickets) do
      add_column :payment_status, String, default: 'pending'  # pending | approved | paid
    end
  end
end
