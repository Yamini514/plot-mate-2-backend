Sequel.migration do
  change do
    # Document vault: typed documents with an expiry date and owner linkage so
    # the system can flag/expire-remind and tag docs to a specific owner, not
    # just a plot.
    alter_table(:documents) do
      add_column :doc_type, String           # agreement | noc | tax_receipt | id_proof | policy | other
      add_column :expiry_date, Date
      add_column :owner_user_id, Integer
      add_column :owner_name, String
      add_index :expiry_date
    end
  end
end
