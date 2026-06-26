class App::Models::Invoice < Sequel::Model
  STATUSES = %w[draft generated sent partially_paid paid overdue cancelled].freeze
  OPEN_STATUSES = %w[generated sent partially_paid overdue].freeze

  many_to_one :plan,  class: 'App::Models::Plan'
  many_to_one :plot,  class: 'App::Models::Plot'
  one_to_many :payments, class: 'App::Models::Payment', key: :invoice_id

  def validate
    super
    validates_presence [:number, :client_id]
    validates_includes STATUSES, :status if status
  end

  def total_paise
    (amount_paise || 0) + (late_fee_paise || 0) + (interest_paise || 0) +
      (tax_paise || 0) - (discount_paise || 0)
  end

  # Recompute balance + status from the money fields. Called after any change
  # to charges, payments, or adjustments.
  def recompute!
    self.balance_paise = total_paise - (paid_paise || 0)

    if status != 'cancelled'
      self.status =
        if balance_paise <= 0
          'paid'
        elsif (paid_paise || 0) > 0
          'partially_paid'
        elsif due_date && due_date < Date.today
          'overdue'
        elsif %w[paid partially_paid].include?(status)
          'sent'
        else
          status # keep draft/generated/sent
        end
    end
    self
  end

  # Apply this invoice's plan late-fee rule once, if overdue and not already applied.
  def apply_late_fee!
    return false if status == 'cancelled' || balance_paise.to_i <= 0
    return false unless due_date && due_date < Date.today
    return false if (late_fee_paise || 0) > 0 # already applied
    return false unless plan_id

    fee = App::Models::Plan[plan_id]&.late_fee_for(amount_paise) || 0
    return false if fee <= 0

    self.late_fee_paise = fee
    recompute!
    save_changes
    true
  end

  # Accrue one month of simple interest on the outstanding balance for an
  # overdue invoice. Idempotent per calendar month via interest_accrued_on, so
  # running it repeatedly (admin action or scheduler) adds at most one charge
  # per month. `rate_percent` is the monthly rate from venture settings.
  def apply_interest!(rate_percent)
    return false if rate_percent.to_f <= 0
    return false if status == 'cancelled' || balance_paise.to_i <= 0
    return false unless due_date && due_date < Date.today
    this_month = Date.today.strftime('%Y-%m')
    return false if interest_accrued_on && interest_accrued_on.strftime('%Y-%m') == this_month

    charge = (balance_paise * rate_percent.to_f / 100).round
    return false if charge <= 0
    self.interest_paise = (interest_paise || 0) + charge
    self.interest_accrued_on = Date.today
    recompute!
    save_changes
    true
  end

  def as_pos
    {
      id: id,
      number: number,
      owner_name: owner_name,
      property: property,
      property_type: property_type,
      plan_name: plan_name,
      category: category || 'maintenance',
      period: period,
      amount: (amount_paise || 0) / 100,
      late_fee: (late_fee_paise || 0) / 100,
      interest: (interest_paise || 0) / 100,
      tax: (tax_paise || 0) / 100,
      discount: (discount_paise || 0) / 100,
      paid: (paid_paise || 0) / 100,
      balance: (balance_paise || 0) / 100,
      issued_on: issued_on,
      due_date: due_date,
      status: status,
      method: payment_method
    }
  end
end
