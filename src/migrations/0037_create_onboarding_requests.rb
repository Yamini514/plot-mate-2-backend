Sequel.migration do
  change do
    # Platform-layer (super-admin) workflow: a prospective venture requests a
    # workspace; the super admin approves it, which provisions a client (venture)
    # and its first Venture Admin login. One request → at most one client.
    create_table(:onboarding_requests) do
      primary_key :id
      String  :code
      String  :venture_name, null: false
      String  :location
      String  :description, text: true
      String  :requester_name, null: false
      String  :requester_email, null: false
      String  :requester_phone
      Integer :plot_count
      String  :notes, text: true

      String  :status, default: 'submitted'  # submitted | approved | rejected
      Integer :client_id                      # the venture created on approval
      Integer :decided_by                     # super-admin user id
      DateTime :decided_at
      String  :decision_reason, text: true

      TrueClass :active, default: true
      Integer :created_by
      Integer :updated_by
      DateTime :created_at, default: Sequel::CURRENT_TIMESTAMP
      DateTime :updated_at, default: Sequel::CURRENT_TIMESTAMP
      index :status
    end
  end
end
