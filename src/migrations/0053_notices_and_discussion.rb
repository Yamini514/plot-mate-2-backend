Sequel.migration do
  change do
    # Notice publishing: targeting (all / block / phase / specific owners),
    # an optional attached document, multi-channel delivery, and acknowledgment
    # tracking. Plus discussion: comments (moderated) and reactions.
    alter_table(:announcements) do
      add_column :audience_type, String, default: 'all'  # all | phase | block | owners
      add_column :audience_values, :jsonb, default: '[]'  # e.g. ["Phase 2"] or ["P-142","P-143"]
      add_column :attachment_url, String, text: true
      add_column :attachment_name, String
      add_column :channels, :jsonb, default: '[]'         # ["in_app","email","whatsapp"]
      add_column :allow_comments, TrueClass, default: true
      add_column :published_at, DateTime
    end

    create_table(:announcement_acks) do
      primary_key :id
      Integer  :client_id, null: false
      Integer  :announcement_id, null: false
      Integer  :user_id
      String   :plot_no
      String   :name
      DateTime :acked_at, default: Sequel::CURRENT_TIMESTAMP
      index [:announcement_id, :user_id], unique: true
    end

    create_table(:announcement_comments) do
      primary_key :id
      Integer  :client_id, null: false
      Integer  :announcement_id, null: false
      Integer  :author_id
      String   :author_name
      String   :body, text: true
      String   :status, default: 'approved'  # pending | approved | hidden
      Integer  :created_by
      Integer  :updated_by
      DateTime :created_at, default: Sequel::CURRENT_TIMESTAMP
      DateTime :updated_at, default: Sequel::CURRENT_TIMESTAMP
      index :announcement_id
    end

    create_table(:announcement_reactions) do
      primary_key :id
      Integer  :client_id, null: false
      Integer  :announcement_id, null: false
      Integer  :user_id
      String   :kind, default: 'like'   # like | celebrate | concerned | ...
      DateTime :created_at, default: Sequel::CURRENT_TIMESTAMP
      index [:announcement_id, :user_id], unique: true
    end
  end
end
