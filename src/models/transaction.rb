class App::Models::Transaction < Sequel::Model
  DIRECTIONS = %w[credit debit].freeze

  def validate
    super
    validates_presence [:client_id, :amount_paise]
    validates_includes DIRECTIONS, :direction if direction
  end

  def as_pos
    {
      id: id,
      direction: direction,
      category: category,
      amount: (amount_paise || 0) / 100,
      payment_id: payment_id,
      invoice_id: invoice_id,
      reference: reference,
      note: note,
      occurred_on: occurred_on
    }
  end
end
