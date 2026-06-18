Sequel.migration do
  change do
    # --- Documents: admin approval + visibility + per-plot scoping ----------
    alter_table(:documents) do
      # admin | owners | plot  — who may see this document.
      add_column :visibility, String, default: 'admin'
      # When visibility = 'plot', the plot the document belongs to.
      add_column :plot_no, String
      # Owners only ever see a document once an admin has approved it.
      add_column :approved, TrueClass, default: false
      add_column :approved_by, String
      add_column :approved_at, DateTime
    end

    # --- Complaints: contact details for the assignee -----------------------
    alter_table(:complaints) do
      add_column :assigned_phone, String
      add_column :assigned_email, String
      add_column :assigned_to_user_id, Integer
    end
  end
end
