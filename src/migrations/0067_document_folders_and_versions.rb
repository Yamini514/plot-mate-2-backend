Sequel.migration do
  change do
    # Hierarchical folders for the document vault.
    create_table(:document_folders) do
      primary_key :id
      Integer  :client_id, null: false
      Integer  :parent_id            # nested folders
      String   :name, null: false
      Integer  :created_by
      DateTime :created_at, default: Sequel::CURRENT_TIMESTAMP
      index [:client_id, :parent_id]
    end

    # Folder placement + version chain on documents.
    alter_table(:documents) do
      add_column :folder_id, Integer
      add_column :version, Integer, default: 1
      add_column :supersedes_id, Integer    # the prior version this replaces
      add_column :superseded, TrueClass, default: false  # hidden from the default (latest) list
      add_index :folder_id
    end
  end
end
