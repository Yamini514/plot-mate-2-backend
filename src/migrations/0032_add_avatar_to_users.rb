Sequel.migration do
  change do
    # Profile photo for app logins. Holds a URL string — either an inline
    # data: URL (works with no storage infra) or an S3/CDN URL once AWS is
    # wired. Same column either way, so storage can switch without a migration.
    alter_table(:users) do
      add_column :avatar_url, String, text: true
    end
  end
end
