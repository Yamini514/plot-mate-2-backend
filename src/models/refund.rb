class App::Models::Refund < Sequel::Model
  STATUSES = %w[pending approved rejected paid].freeze
  METHODS  = %w[upi bank cash adjustment].freeze

  many_to_one :payment, class: 'App::Models::Payment'

  def validate
    super
    validates_presence [:client_id, :payment_id, :amount_paise]
    validates_includes STATUSES, :status if status
    validates_includes METHODS, :method if method
  end

  def as_pos
    pmt = payment
    { id: id, code: code, payment_id: payment_id, plot_id: plot_id,
      amount: (amount_paise || 0) / 100, reason: reason, method: method,
      status: status || 'pending', approved_at: approved_at,
      payment_number: pmt&.number, owner_name: pmt&.owner_name,
      created_at: created_at }
  end
end
