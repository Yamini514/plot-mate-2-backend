class App::Models::OnboardingRequest < Sequel::Model(:onboarding_requests)
  STATUSES = %w[submitted approved rejected].freeze
  EMAIL_RE = /\A[^@\s]+@[^@\s]+\.[^@\s]+\z/

  def validate
    super
    validates_presence [:venture_name, :requester_name, :requester_email]
    validates_includes STATUSES, :status if status
    if requester_email.to_s.strip != '' && requester_email.to_s.strip !~ EMAIL_RE
      errors.add(:requester_email, 'must be a valid email address')
    end
  end

  def pending? = status == 'submitted'

  def as_pos
    { id: id, code: code, venture_name: venture_name, location: location,
      description: description, requester_name: requester_name,
      requester_email: requester_email, requester_phone: requester_phone,
      plot_count: plot_count, notes: notes, status: status, client_id: client_id,
      decided_by: decided_by, decided_at: decided_at, decision_reason: decision_reason,
      created_at: created_at }
  end
end
