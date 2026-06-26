Sequel.migration do
  change do
    # Venture ↔ platform support. Distinct from the venture-scoped `tickets`
    # table (resident service requests): these are raised by a Venture Admin to
    # the platform, or opened by the super admin about a venture.
    create_table(:platform_tickets) do
      primary_key :id
      String   :code                      # PT-1042
      Integer  :client_id                 # raising venture (nullable for platform-internal)
      Integer  :raised_by                 # user id
      String   :raised_by_name
      String   :subject, null: false
      String   :description, text: true
      String   :category                  # billing | technical | onboarding | abuse | feature | other
      String   :priority, default: 'medium'  # low | medium | high | critical
      String   :status, default: 'open'      # open | assigned | in_progress | waiting_venture | resolved | closed | escalated
      Integer  :assigned_to               # super-admin / platform-staff user id
      String   :escalation_level, default: 'l1'  # l1 | l2 | l3
      DateTime :resolved_at
      Integer  :created_by
      Integer  :updated_by
      DateTime :created_at, default: Sequel::CURRENT_TIMESTAMP
      DateTime :updated_at, default: Sequel::CURRENT_TIMESTAMP
      index [:status, :priority]
      index :client_id
    end

    create_table(:platform_ticket_messages) do
      primary_key :id
      Integer  :platform_ticket_id, null: false
      Integer  :author_id
      String   :author_name
      String   :author_role
      String   :body, text: true
      TrueClass :internal, default: false  # internal note vs reply visible to the venture
      DateTime :created_at, default: Sequel::CURRENT_TIMESTAMP
      index :platform_ticket_id
    end
  end
end
