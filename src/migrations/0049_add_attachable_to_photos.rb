Sequel.migration do
  change do
    # Make photos polymorphically attachable so the same store backs site
    # photos, ticket before/after work photos, and project progress photos.
    # A null attachable = a plain site photo (the original behaviour).
    alter_table(:photos) do
      add_column :attachable_type, String   # Ticket | Project | MaintenanceLog
      add_column :attachable_id, Integer
      add_column :kind, String, default: 'general'  # general | before | after | progress
      add_index [:attachable_type, :attachable_id]
    end
  end
end
