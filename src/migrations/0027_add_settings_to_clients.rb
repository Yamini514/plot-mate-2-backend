Sequel.migration do
  change do
    alter_table(:clients) do
      add_column :settings, :jsonb, default: '{}'  # association config: rate, bank, committee
    end
  end
end
