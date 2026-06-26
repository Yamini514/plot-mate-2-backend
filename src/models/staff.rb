class App::Models::Staff < Sequel::Model(:staff)
  STATUSES = %w[active on_leave inactive].freeze
  KINDS    = %w[staff vendor].freeze
  PHONE_RE = /\A\d{10}\z/ # optional, but 10 digits when present

  def validate
    super
    validates_presence [:client_id, :name]
    validates_includes KINDS, :kind if kind
    if phone.to_s.strip != '' && phone.to_s.strip !~ PHONE_RE
      errors.add(:phone, 'must be a 10-digit number')
    end
  end

  # A vendor is eligible for work-order assignment when it's an active, verified
  # vendor (unexpired compliance docs are enforced in the service filter).
  def eligible_vendor? = kind == 'vendor' && verified && status == 'active'

  def as_pos
    { id: id, code: code, name: name, role: role, phone: phone, email: email,
      monthly_salary: (monthly_salary_paise || 0) / 100, joined_on: joined_on,
      status: status, type: kind,
      # vendor profile (migration 0048)
      categories: (categories || []), license_no: license_no, license_expiry: license_expiry,
      insurance_policy: insurance_policy, insurance_expiry: insurance_expiry,
      sla_response_hours: sla_response_hours, rate_card: rate_card,
      verified: !!verified, preferred: !!preferred }
  end
end
