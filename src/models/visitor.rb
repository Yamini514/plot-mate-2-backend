class App::Models::Visitor < Sequel::Model
  STATUSES = %w[pending approved inside checked_out rejected expected left].freeze

  def validate
    super
    validates_presence [:client_id, :name]
    validates_includes STATUSES, :status if status
  end

  # Map a guard action to the resulting status + timestamp side-effects.
  def apply_action!(action)
    case action
    when 'approve'  then self.status = 'approved'
    when 'reject'   then self.status = 'rejected'
    when 'checkin'  then self.status = 'inside';       self.check_in = Time.now
    when 'checkout' then self.status = 'checked_out';  self.check_out = Time.now
    else return false
    end
    save_changes
    true
  end

  def self.gen_pass_code
    "GP-#{SecureRandom.alphanumeric(6).upcase}"
  end

  def as_pos
    { id: id, code: code, name: name, phone: phone, resident_name: resident_name,
      plot_no: plot_no, purpose: purpose, vehicle_no: vehicle_no,
      check_in: check_in, check_out: check_out, status: status,
      pass_code: pass_code, expected_on: expected_on }
  end
end
