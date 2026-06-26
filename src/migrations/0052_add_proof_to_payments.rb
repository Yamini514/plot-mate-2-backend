Sequel.migration do
  change do
    # Let owners/admins attach proof of payment (a bank screenshot / receipt
    # image) to a recorded payment, alongside the free-text reference.
    alter_table(:payments) do
      add_column :proof_url, String, text: true   # uploaded image/PDF (S3 URL or data URL)
      add_column :proof_key, String                # S3 object key, when hosted
    end
  end
end
