Sequel.migration do
  change do
    # Per-venture custom committee roles with a granular permission list. These
    # describe a committee member's responsibilities and can be named as the
    # approver in the venture's approval matrix (stored in clients.settings
    # under 'approval_matrix'). They do NOT replace the auth role enum on users.
    create_table(:roles) do
      primary_key :id
      Integer   :client_id, null: false
      String    :name, null: false
      String    :description
      column    :permissions, :jsonb, default: '[]'
      TrueClass :active, default: true
      Integer   :created_by
      Integer   :updated_by
      DateTime  :created_at, default: Sequel::CURRENT_TIMESTAMP
      DateTime  :updated_at, default: Sequel::CURRENT_TIMESTAMP
      index [:client_id, :name]
    end

    # How outstanding dues are handled when a transfer completes:
    #   carry → the new owner inherits the ledger (default, prior behaviour)
    #   clear → open invoices are written off and the plot's balance is zeroed
    alter_table(:transfers) do
      add_column :dues_action, String, default: 'carry'
    end
  end
end
