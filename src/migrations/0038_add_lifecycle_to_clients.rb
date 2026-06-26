Sequel.migration do
  change do
    # Explicit venture lifecycle on the platform layer. `active` stays the fast
    # access-gate boolean (suspended ⇒ active=false); `status` is the human /
    # reporting lifecycle the super-admin dashboard counts and filters on.
    alter_table(:clients) do
      # pending | approved | active | modifications_requested | suspended | rejected | archived
      add_column :status, String, default: 'active'
      add_column :suspended_at, DateTime
      add_column :suspended_by, Integer        # super-admin user id
      add_column :suspension_reason, String, text: true
      add_column :approved_at, DateTime
      add_column :approved_by, Integer
      add_column :onboarding_request_id, Integer  # provenance: the request this venture came from
      add_index  :status
    end
  end
end


