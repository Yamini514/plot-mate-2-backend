class App::Models::OnboardingRequest < Sequel::Model(:onboarding_requests)
  STATUSES = %w[submitted changes_requested approved rejected].freeze
  EMAIL_RE = /\A[^@\s]+@[^@\s]+\.[^@\s]+\z/

  one_to_many :onboarding_documents, key: :onboarding_request_id

  def validate
    super
    validates_presence [:venture_name, :requester_name, :requester_email]
    validates_includes STATUSES, :status if status
    if requester_email.to_s.strip != '' && requester_email.to_s.strip !~ EMAIL_RE
      errors.add(:requester_email, 'must be a valid email address')
    end
  end

  # Pending = awaiting/continuing the super admin's decision. `changes_requested`
  # is still actionable (the requester can amend and the super admin approve).
  def pending? = %w[submitted changes_requested].include?(status)

  def as_pos(with_documents: false)
    base = { id: id, code: code, venture_name: venture_name, location: location,
      description: description, requester_name: requester_name,
      requester_email: requester_email, requester_phone: requester_phone,
      plot_count: plot_count, notes: notes, status: status, client_id: client_id,
      decided_by: decided_by, decided_at: decided_at, decision_reason: decision_reason,
      created_at: created_at }
    base[:documents] = onboarding_documents.map(&:as_pos) if with_documents
    base
  end
end
