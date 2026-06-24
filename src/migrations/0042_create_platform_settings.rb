Sequel.migration do
  change do
    # Platform-wide config, mirroring the per-venture clients.settings pattern.
    # Singleton row (id=1), lazily created by PlatformSettings#row — not seeded
    # here, since the migrate task connects without the pg_json extension.
    create_table(:platform_settings) do
      primary_key :id
      column   :settings, :jsonb, default: '{}'
      Integer  :updated_by
      DateTime :updated_at, default: Sequel::CURRENT_TIMESTAMP
    end
  end
end
