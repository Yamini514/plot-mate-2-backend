class App::Models::Plot < Sequel::Model
  PAYMENT_STATUSES = %w[paid pending unknown].freeze
  MEMBERSHIPS      = %w[verified unverified].freeze

  # Annual maintenance rate. Lives here for now; belongs in association
  # settings once that module exists. Stored in paise (₹30 / sqyd).
  RATE_PER_SQYD_PAISE = 30 * 100

  def validate
    super
    validates_presence [:plot_no, :client_id]
    validates_includes PAYMENT_STATUSES, :payment_status if payment_status
    validates_includes MEMBERSHIPS, :membership if membership
    validates_unique([:client_id, :plot_no]) { |ds| ds.where(active: true) }
  end

  # Maintenance dues = size × rate, cleared to zero once paid.
  def recompute_dues!
    self.amount_due_paise =
      payment_status == 'paid' ? 0 : (size_sqyd.to_i * RATE_PER_SQYD_PAISE)
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
