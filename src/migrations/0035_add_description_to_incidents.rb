Sequel.migration do
  change do
    # The guard incident form has always collected a description; give it a
    # column so the narrative is actually stored (and shown back) instead of
    # being dropped on submit.
    add_column :incidents, :description, String, text: true
  end
end
