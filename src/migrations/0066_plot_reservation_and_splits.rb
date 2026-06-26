Sequel.migration do
  change do
    # Plot reservation (a temporary hold) + merge/split lineage.
    alter_table(:plots) do
      add_column :reserved_until, DateTime
      add_column :reserved_for, String          # name/note of who it's held for
      add_column :merged_into_id, Integer        # this plot was merged into another
      add_column :split_from_id, Integer         # this plot was split off another
    end
  end
end
