Sequel.migration do
  change do
    # Ownership transfer of a plot from the current owner to a new one. The
    # decision itself routes through the shared approval engine (request_type
    # 'ownership_transfer'); this table holds the transfer-specific detail and
    # the supporting documents (sale deed / NOC) as a jsonb list.
    create_table(:transfers) do
      primary_key :id
      Integer  :client_id, null: false
      String   :code                      # TRF-1001
      Integer  :plot_id, null: false

      String   :from_owner_name
      String   :from_email
      String   :from_phone
      Integer  :from_user_id

      String   :to_owner_name, null: false
      String   :to_email
      String   :to_phone
      Integer  :to_user_id

      String   :reason                    # sale | gift | inheritance | other
      Integer  :outstanding_paise         # dues snapshot at initiation
      column   :docs, :jsonb, default: '[]'  # [{name,url,doc_type}]

      # initiated | under_review | approved | rejected | completed | cancelled
      String   :status, default: 'initiated'
      Integer  :approval_request_id       # link to the approval engine
      String   :notes, text: true
      Integer  :decided_by
      DateTime :decided_at

      Integer  :created_by
      Integer  :updated_by
      DateTime :created_at, default: Sequel::CURRENT_TIMESTAMP
      DateTime :updated_at, default: Sequel::CURRENT_TIMESTAMP
      index [:client_id, :status]
      index :plot_id
    end
  end
end
