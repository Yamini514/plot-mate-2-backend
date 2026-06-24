class App::Models::OnboardingDocument < Sequel::Model
  DOC_TYPES = %w[registration layout_map tax ownership_proof other].freeze
  STATUSES  = %w[pending verified rejected].freeze

  def validate
    super
    validates_presence [:onboarding_request_id, :name]
    validates_includes DOC_TYPES, :doc_type if doc_type
    validates_includes STATUSES, :status    if status
  end

  def as_pos
    { id: id, code: code, doc_type: doc_type, name: name, url: url, size: size,
      status: status || 'pending', review_note: review_note,
      reviewed_by: reviewed_by, reviewed_at: reviewed_at, created_at: created_at }
  end
end
