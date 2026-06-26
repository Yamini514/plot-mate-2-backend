class App::Models::ApprovalRequest < Sequel::Model
  one_to_many :approval_actions, key: :approval_request_id, order: :created_at

  TYPES    = %w[owner_verification plot_claim ownership_transfer document_verification other].freeze
  STATUSES = %w[submitted under_review changes_requested approved rejected].freeze
  OPEN_STATUSES = %w[submitted under_review changes_requested].freeze

  def validate
    super
    validates_presence [:client_id, :request_type]
    validates_includes STATUSES, :status if status
  end

  def open? = OPEN_STATUSES.include?(status)

  # Which role should review a given request type, from the venture's approval
  # matrix (clients.settings['approval_matrix']); falls back to 'admin'. This is
  # the configurable routing that replaces the previously hardcoded 'admin'.
  def self.role_for(client_id, request_type)
    matrix = (App::Models::Client[client_id]&.settings || {})['approval_matrix'] || {}
    (matrix[request_type.to_s].presence || 'admin')
  rescue StandardError
    'admin'
  end

  # Create a request + its first "submitted" timeline entry. Used by any flow
  # that needs a decision (invite accept, plot claim, transfer, document review).
  # current_role defaults to the matrix-resolved approver for the request type.
  def self.open!(client_id:, request_type:, subject: nil, subject_type: nil,
                 subject_id: nil, payload: {}, submitted_by: nil,
                 submitted_by_name: nil, current_role: nil)
    current_role ||= role_for(client_id, request_type)
    st  = subject_type || (subject && subject.class.name.split('::').last)
    sid = subject_id   || subject&.id
    req = create(client_id: client_id, request_type: request_type, subject_type: st,
                 subject_id: sid, payload: payload, submitted_by: submitted_by,
                 submitted_by_name: submitted_by_name, status: 'submitted',
                 current_role: current_role)
    req.update(code: "APR-#{1000 + req.id}") if req.id
    req.record!('submitted', actor_id: submitted_by, actor_name: submitted_by_name)
    req
  end

  # Append a timeline entry (who did what). The audit trail per request.
  def record!(action, actor_id: nil, actor_name: nil, actor_role: nil, note: nil, meta: {})
    App::Models::ApprovalAction.create(
      approval_request_id: id, actor_id: actor_id, actor_name: actor_name,
      actor_role: actor_role, action: action.to_s, note: note, meta: meta || {}
    )
  end

  def as_pos(with_timeline: false)
    base = { id: id, code: code, request_type: request_type,
             subject_type: subject_type, subject_id: subject_id,
             submitted_by: submitted_by, submitted_by_name: submitted_by_name,
             status: status, current_role: current_role, payload: payload || {},
             decision_reason: decision_reason, decided_by: decided_by,
             decided_at: decided_at, created_at: created_at }
    base[:timeline] = approval_actions.map(&:as_pos) if with_timeline
    base
  end
end
