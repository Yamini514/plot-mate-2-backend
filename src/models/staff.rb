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

  def as_pos
    { id: id, code: code, name: name, role: role, phone: phone,
      monthly_salary: (monthly_salary_paise || 0) / 100, joined_on: joined_on,
      status: status, type: kind }
  end
end
