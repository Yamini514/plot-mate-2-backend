class App::Models::InvoiceAdjustment < Sequel::Model
  KINDS = %w[waiver discount credit].freeze

  many_to_one :invoice, class: 'App::Models::Invoice'

  def validate
    super
    validates_presence [:client_id, :invoice_id, :amount_paise]
    validates_includes KINDS, :kind if kind
  end

  def as_pos
    {
      id: id,
      invoice_id: invoice_id,
      kind: kind,
      amount: (amount_paise || 0) / 100,
      reason: reason,
      created_at: created_at
    }
  end
end
