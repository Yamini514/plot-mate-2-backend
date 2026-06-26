Sequel.migration do
  change do
    # Discrete milestones for a project (the audit's missing "milestones" piece).
    create_table(:project_milestones) do
      primary_key :id
      Integer  :client_id, null: false
      Integer  :project_id, null: false
      String   :title, null: false
      Date     :due_on
      String   :status, default: 'pending'   # pending | done
      Date     :done_on
      Integer  :sort_order, default: 0
      Integer  :created_by
      Integer  :updated_by
      DateTime :created_at, default: Sequel::CURRENT_TIMESTAMP
      DateTime :updated_at, default: Sequel::CURRENT_TIMESTAMP
      index :project_id
    end

    # Owner/admin discussion on a project (mirrors announcement comments). Member
    # comments can be moderated to a pending queue via the client setting.
    create_table(:project_comments) do
      primary_key :id
      Integer  :client_id, null: false
      Integer  :project_id, null: false
      Integer  :author_id
      String   :author_name
      String   :body, text: true
      String   :status, default: 'approved'  # pending | approved | hidden
      DateTime :created_at, default: Sequel::CURRENT_TIMESTAMP
      DateTime :updated_at, default: Sequel::CURRENT_TIMESTAMP
      index :project_id
    end

    create_table(:project_reactions) do
      primary_key :id
      Integer  :client_id, null: false
      Integer  :project_id, null: false
      Integer  :user_id, null: false
      String   :kind, default: 'like'        # like | celebrate | concerned
      DateTime :created_at, default: Sequel::CURRENT_TIMESTAMP
      DateTime :updated_at, default: Sequel::CURRENT_TIMESTAMP
      index [:project_id, :user_id], unique: true
    end
  end
end
