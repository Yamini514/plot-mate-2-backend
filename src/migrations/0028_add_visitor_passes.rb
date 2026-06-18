Sequel.migration do
  change do
    alter_table(:visitors) do
      add_column :pass_code, String     # gate pass / QR code for pre-approved visitors
      add_column :expected_on, Date     # date the visitor is expected
    end
  end
end
