Sequel.migration do
  change do
    # `active` already gates login; these record WHY/WHEN a super admin blocked
    # an account, for the audit story. Block = active=false + reason.
    alter_table(:users) do
      add_column :blocked_at, DateTime
      add_column :blocked_by, Integer
      add_column :block_reason, String, text: true
    end
  end
end
