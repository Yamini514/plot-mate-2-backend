Sequel.migration do
  change do
    # KYC / verification state for owners (and any user). `kyc_data` holds the
    # submitted detail (id type/number, address, doc references); `kyc_status`
    # drives the admin verification queue and the "pending KYC" account state.
    alter_table(:users) do
      add_column :kyc_status, String, default: 'not_submitted'  # not_submitted | submitted | verified | rejected
      add_column :kyc_data, :jsonb, default: '{}'
      add_column :verified_at, DateTime
      add_column :verified_by, Integer
    end
  end
end
