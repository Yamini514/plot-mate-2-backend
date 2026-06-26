Sequel.migration do
  change do
    # Platform-wide announcements the super admin broadcasts to ventures (the
    # Global Notification Center). Distinct from the venture-scoped `announcements`
    # table (resident notices). Audience is every venture, or a selected subset.
    create_table(:platform_announcements) do
      primary_key :id
      String   :code
      String   :title, null: false
      String   :message, text: true
      String   :priority, default: 'normal'    # low | normal | high | critical
      String   :audience, default: 'all'        # all | selected
      column   :client_ids, :jsonb, default: '[]'   # target ventures when audience = selected
      String   :status, default: 'draft'        # draft | scheduled | published
      DateTime :start_at
      DateTime :end_at
      DateTime :published_at
      Integer  :created_by
      Integer  :updated_by
      DateTime :created_at, default: Sequel::CURRENT_TIMESTAMP
      DateTime :updated_at, default: Sequel::CURRENT_TIMESTAMP
      index :status
    end
  end
end
