Sequel.migration do
  change do
    # Admin-issued invite links. The venture admin creates an invite for a
    # member/owner (optionally pre-linked to a plot); the recipient opens the
    # tokenized link and self-completes their profile + KYC. No open public
    # signup — an invite must exist first (admin-driven onboarding).
    create_table(:invites) do
      primary_key :id
      Integer  :client_id, null: false
      String   :code                        # INV-1001
      String   :token, null: false          # urlsafe, unique — the link secret
      String   :email
      String   :full_name
      Integer  :role, default: 0            # member | guard | admin (User::ROLES)
      Integer  :plot_id                     # optional: owner ↔ plot pre-link
      String   :status, default: 'pending'  # pending | accepted | revoked | expired
      Integer  :user_id                     # the user created once accepted
      Integer  :invited_by
      DateTime :expires_at
      DateTime :accepted_at
      Integer  :created_by
      Integer  :updated_by
      DateTime :created_at, default: Sequel::CURRENT_TIMESTAMP
      DateTime :updated_at, default: Sequel::CURRENT_TIMESTAMP
      index :token, unique: true
      index [:client_id, :status]
    end
  end
end
