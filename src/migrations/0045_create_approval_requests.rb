Sequel.migration do
  change do
    # Generic request/approval engine. One row per pending decision (owner
    # verification, plot claim, ownership transfer, document verification, …),
    # routed to an approver role via the venture's approval matrix. The paired
    # approval_actions table is the step-by-step timeline: who submitted, routed,
    # reviewed, approved/rejected — a full audit trail per request.
    create_table(:approval_requests) do
      primary_key :id
      Integer  :client_id, null: false
      String   :code                          # APR-1001
      String   :request_type, null: false     # owner_verification | plot_claim | ownership_transfer | document_verification | other
      String   :subject_type                  # Plot | User | Document | Transfer
      Integer  :subject_id
      Integer  :submitted_by
      String   :submitted_by_name
      String   :status, default: 'submitted'  # submitted | under_review | changes_requested | approved | rejected
      String   :current_role                  # whose queue it's in (matrix-driven), e.g. 'admin'
      column   :payload, :jsonb, default: '{}' # request-specific data
      String   :decision_reason, text: true
      Integer  :decided_by
      DateTime :decided_at
      Integer  :created_by
      Integer  :updated_by
      DateTime :created_at, default: Sequel::CURRENT_TIMESTAMP
      DateTime :updated_at, default: Sequel::CURRENT_TIMESTAMP
      index [:client_id, :status]
      index :request_type
      index [:subject_type, :subject_id]
    end

    create_table(:approval_actions) do
      primary_key :id
      Integer  :approval_request_id, null: false
      Integer  :actor_id
      String   :actor_name
      String   :actor_role
      String   :action, null: false   # submitted | routed | reviewed | approved | rejected | changes_requested | commented
      String   :note, text: true
      column   :meta, :jsonb, default: '{}'
      DateTime :created_at, default: Sequel::CURRENT_TIMESTAMP
      index :approval_request_id
    end
  end
end
