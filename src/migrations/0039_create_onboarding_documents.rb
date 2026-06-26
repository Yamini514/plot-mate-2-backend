Sequel.migration do
  change do
    # Onboarding documents exist BEFORE a venture (client) does, so they can't
    # live in `documents` (which requires client_id). Keyed to the request; on
    # approval the layout_map doc is handed to the new venture's PlotLayout.
    create_table(:onboarding_documents) do
      primary_key :id
      Integer  :onboarding_request_id, null: false
      String   :code
      String   :doc_type        # registration | layout_map | tax | ownership_proof | other
      String   :name, null: false
      String   :file_key        # S3 object key (reuse Uploads#presign)
      String   :url
      String   :size
      String   :status, default: 'pending'   # pending | verified | rejected
      String   :review_note, text: true
      Integer  :reviewed_by
      DateTime :reviewed_at
      Integer  :created_by
      Integer  :updated_by
      DateTime :created_at, default: Sequel::CURRENT_TIMESTAMP
      DateTime :updated_at, default: Sequel::CURRENT_TIMESTAMP
      index :onboarding_request_id
    end
  end
end
