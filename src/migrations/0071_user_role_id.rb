Sequel.migration do
  change do
    # RBAC: link a committee/staff user (user-enum admin = 2) to a custom `roles`
    # row whose module.action permissions gate their access. A role-2 user with a
    # NULL role_id is the venture owner-admin (implicitly all permissions).
    alter_table(:users) do
      add_column :role_id, Integer
      add_index :role_id
    end

    # Mark roles that are seeded templates (President, Treasurer, …) so the UI can
    # distinguish them from venture-custom roles.
    alter_table(:roles) do
      add_column :is_template, TrueClass, default: false
    end
  end
end
