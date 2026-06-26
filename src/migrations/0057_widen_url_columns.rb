Sequel.migration do
  change do
    # These url columns can now hold inline `data:` URLs (member helpdesk work
    # photos, the public venture-registration layout upload, and document-vault
    # uploads done without S3), which far exceed the default varchar(255).
    set_column_type :photos, :url, :text
    set_column_type :documents, :url, :text
    set_column_type :onboarding_documents, :url, :text
  end
end
