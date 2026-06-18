class App::Models::Plot < Sequel::Model
  PAYMENT_STATUSES = %w[paid pending unknown].freeze
  MEMBERSHIPS      = %w[verified unverified].freeze

  def validate
    super
    validates_presence [:plot_no, :client_id]
    validates_includes PAYMENT_STATUSES, :payment_status if payment_status
    validates_includes MEMBERSHIPS, :membership if membership
    validates_unique([:client_id, :plot_no]) { |ds| ds.where(active: true) }
  end

  # Set the maintenance due from a base-pay amount (paise). The amount itself is
  # computed by the service from the association's configured rule (per-sqyd or
  # flat per-plot) — never hardcoded here. Paid plots always clear to zero.
  def set_base_pay!(base_paise)
    self.amount_due_paise = payment_status == 'paid' ? 0 : base_paise.to_i
    self
  end

  def amount_due_rupees
    (amount_due_paise || 0) / 100
  end

  def as_pos
    {
      id: id,
      plot_no: plot_no,
      owner_name: owner_name,
      phone: phone,
      email: email,
      size_sqyd: size_sqyd,
      phase: phase,
      membership: membership,
      payment_status: payment_status,
      amount_due: amount_due_rupees,
      last_payment_date: last_payment_date,
      days_overdue: days_overdue,
      active: active
    }
  end
end
