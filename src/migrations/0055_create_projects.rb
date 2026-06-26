Sequel.migration do
  change do
    # Capital / improvement projects: budget, timeline, scope (affected
    # areas/plots), an assigned vendor/team, and a progress log. Progress photos
    # reuse the polymorphic Photo store (attachable_type 'Project').
    create_table(:projects) do
      primary_key :id
      Integer  :client_id, null: false
      String   :code                       # PRJ-1001
      String   :name, null: false
      String   :description, text: true
      Integer  :budget_paise, default: 0
      Integer  :spent_paise, default: 0
      # planned | active | on_hold | delayed | completed | cancelled
      String   :status, default: 'planned'
      Integer  :progress_percent, default: 0
      Date     :start_date
      Date     :target_date
      Date     :completed_on
      Integer  :vendor_staff_id            # assigned vendor/team (Staff)
      String   :vendor_name
      column   :affected_areas, :jsonb, default: '[]'   # ["Clubhouse","Phase 2 road"]
      column   :affected_plots, :jsonb, default: '[]'   # ["P-142", ...]
      Integer  :created_by
      Integer  :updated_by
      DateTime :created_at, default: Sequel::CURRENT_TIMESTAMP
      DateTime :updated_at, default: Sequel::CURRENT_TIMESTAMP
      index [:client_id, :status]
    end

    create_table(:project_updates) do
      primary_key :id
      Integer  :client_id, null: false
      Integer  :project_id, null: false
      String   :title
      String   :note, text: true
      Integer  :percent                    # progress snapshot at this update
      Integer  :spent_paise                # incremental spend logged with the update
      TrueClass :is_delay, default: false   # flags a delay
      String   :author_name
      Integer  :created_by
      Integer  :updated_by
      DateTime :created_at, default: Sequel::CURRENT_TIMESTAMP
      DateTime :updated_at, default: Sequel::CURRENT_TIMESTAMP
      index :project_id
    end
  end
end
