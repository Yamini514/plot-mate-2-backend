class App::Models::Staff < Sequel::Model(:staff)
  STATUSES = %w[active on_leave inactive].freeze
  KINDS    = %w[staff vendor].freeze

  def validate
    super
    validates_presence [:client_id, :name]
    validates_includes KINDS, :kind if kind
  end

  def as_pos
    { id: id, code: code, name: name, role: role, phone: phone,
      monthly_salary: (monthly_salary_paise || 0) / 100, joined_on: joined_on,
      status: status, type: kind }
  end
end
