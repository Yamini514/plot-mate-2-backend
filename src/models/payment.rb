class App::Models::Payment < Sequel::Model
  MODES = %w[upi bank cash card net_banking].freeze

  many_to_one :invoice, class: 'App::Models::Invoice'

  # Indian financial year label for a date, e.g. 2026-04-12 -> "2026-27".
  def self.fy_for(date)
    y = date.year
    date.month >= 4 ? "#{y}-#{(y + 1).to_s[-2, 2]}" : "#{y - 1}-#{y.to_s[-2, 2]}"
  end

  def self.next_payment_number(client_id)
    "PMT-#{1000 + where(client_id: client_id).count + 1}"
  end

  def self.next_receipt_number(client_id)
    year = Date.today.year
    seq = where(client_id: client_id)
            .where(Sequel.like(:receipt_number, "RCPT-#{year}-%")).count + 1
    "RCPT-#{year}-#{format('%04d', seq)}"
  end

  # Record a payment against an invoice: create the payment + receipt, apply it
  # to the invoice balance/status, and post a credit to the treasury ledger —
  # all atomically so the books always reconcile with billing.
  def self.record!(invoice:, amount_paise:, mode: 'cash', reference: nil,
                   paid_on: nil, note: nil, provider: 'manual', provider_ref: nil)
    raise ArgumentError, 'amount must be positive' if amount_paise.to_i <= 0

    paid_on ||= Date.today
    App.db.transaction do
      pmt = create(
        client_id:      invoice.client_id,
        invoice_id:     invoice.id,
        plot_id:        invoice.plot_id,
        owner_name:     invoice.owner_name,
        property:       invoice.property,
        amount_paise:   amount_paise,
        mode:           mode,
        reference:      reference,
        provider:       provider,
        provider_ref:   provider_ref,
        paid_on:        paid_on,
        note:           note,
        number:         next_payment_number(invoice.client_id),
        receipt_number: next_receipt_number(invoice.client_id),
        fy:             fy_for(paid_on)
      )

      invoice.paid_paise = (invoice.paid_paise || 0) + amount_paise
      invoice.payment_method = mode
      invoice.recompute!
      invoice.save_changes

      App::Models::Transaction.create(
        client_id:    invoice.client_id,
        direction:    'credit',
        category:     'maintenance',
        amount_paise: amount_paise,
        payment_id:   pmt.id,
        invoice_id:   invoice.id,
        reference:    pmt.receipt_number,
        note:         "Payment for #{invoice.number}",
        occurred_on:  paid_on
      )
      pmt
    end
  end

  def validate
    super
    validates_presence [:client_id, :amount_paise]
    validates_includes MODES, :mode if mode
  end

  def as_pos
    inv = invoice
    {
      id: id,
      number: number,
      receipt_number: receipt_number,
      invoice_id: invoice_id,
      invoice_number: inv&.number,
      # What the payment was for — the plan/period of the linked invoice, so the
      # receipt list can show purpose, not just an amount.
      plan_name: inv&.plan_name,
      period: inv&.period,
      purpose: inv&.plan_name || 'Maintenance',
      owner_name: owner_name,
      property: property,
      amount: (amount_paise || 0) / 100,
      mode: mode,
      reference: reference,
      provider: provider,
      paid_on: paid_on,
      fy: fy,
      note: note
    }
  end

  # Receipt payload for the member/admin receipt view + PDF.
  def as_receipt
    inv = invoice
    {
      receipt_number: receipt_number,
      payment_number: number,
      paid_on: paid_on,
      amount: (amount_paise || 0) / 100,
      mode: mode,
      reference: reference,
      owner_name: owner_name,
      property: property,
      invoice_number: inv&.number,
      plan_name: inv&.plan_name,
      period: inv&.period
    }
  end
end
