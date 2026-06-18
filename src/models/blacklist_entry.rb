class App::Models::BlacklistEntry < Sequel::Model
  KINDS    = %w[visitor vehicle].freeze
  STATUSES = %w[blacklisted flagged].freeze

  def validate
    super
    validates_presence [:client_id]
    validates_includes KINDS, :kind if kind
  end

  def as_pos
    { id: id, code: code, kind: kind, name: name, phone: phone, plate: plate,
      model: model, reason: reason, added_by: added_by, attempts: attempts, status: status }
  end
end
