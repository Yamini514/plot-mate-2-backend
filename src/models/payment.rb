class App::Models::Payment < Sequel::Model
  MODES = %w[upi bank cash card net_banking].freeze
  VERIFICATION = %w[pending verified rejected].freeze

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

  # Create the payment row only — no books touched. Shared by record! (admin,
  # immediate) and submit! (member self-report, pending verification).
  def self.build_for(invoice:, amount_paise:, mode:, verification_status:,
                     reference: nil, paid_on: nil, note: nil, provider: 'manual',
                     provider_ref: nil, proof_url: nil, proof_key: nil,
                     submitted_by_user_id: nil)
    raise ArgumentError, 'amount must be positive' if amount_paise.to_i <= 0
    paid_on ||= Date.today
    create(
      client_id: invoice.client_id, invoice_id: invoice.id, plot_id: invoice.plot_id,
      owner_name: invoice.owner_name, property: invoice.property,
      amount_paise: amount_paise, mode: mode, reference: reference,
      provider: provider, provider_ref: provider_ref,
      proof_url: proof_url, proof_key: proof_key, paid_on: paid_on, note: note,
      number: next_payment_number(invoice.client_id), fy: fy_for(paid_on),
      verification_status: verification_status, submitted_by_user_id: submitted_by_user_id
    )
  end

  # Record a verified payment and apply it immediately — admin recording, the
  # Stripe webhook, and bulk mark-paid. Atomic so the books always reconcile.
  def self.record!(invoice:, amount_paise:, mode: 'cash', reference: nil,
                   paid_on: nil, note: nil, provider: 'manual', provider_ref: nil,
                   proof_url: nil, proof_key: nil)
    App.db.transaction do
      pmt = build_for(invoice: invoice, amount_paise: amount_paise, mode: mode,
                      reference: reference, paid_on: paid_on, note: note,
                      provider: provider, provider_ref: provider_ref,
                      proof_url: proof_url, proof_key: proof_key,
                      verification_status: 'verified')
      pmt.apply_to_books!(invoice)
      pmt
    end
  end

  # Member-reported offline payment: created as `pending`. The books are NOT
  # touched until an admin verifies it (verify!).
  def self.submit!(invoice:, amount_paise:, mode: 'upi', reference: nil,
                   paid_on: nil, note: nil, proof_url: nil, proof_key: nil,
                   submitted_by_user_id: nil)
    build_for(invoice: invoice, amount_paise: amount_paise, mode: mode,
              reference: reference, paid_on: paid_on, note: note,
              proof_url: proof_url, proof_key: proof_key,
              verification_status: 'pending', submitted_by_user_id: submitted_by_user_id)
  end

  # Apply to the invoice balance/status, mint the receipt, post a treasury
  # credit, and cancel the plot's reminders once dues clear. Called once — by
  # record! (immediate) or verify! (after approval).
  def apply_to_books!(inv = invoice)
    self.receipt_number ||= self.class.next_receipt_number(inv.client_id)
    save_changes

    inv.paid_paise = (inv.paid_paise || 0) + amount_paise
    inv.payment_method = mode
    inv.recompute!
    inv.save_changes

    App::Models::Transaction.create(
      client_id: inv.client_id, direction: 'credit',
      category: inv.category || 'maintenance', amount_paise: amount_paise,
      payment_id: id, invoice_id: inv.id, reference: receipt_number,
      note: "Payment for #{inv.number}", occurred_on: paid_on
    )

    if inv.plot_id && inv.balance_paise.to_i <= 0
      App::Models::Reminder
        .where(client_id: inv.client_id, plot_id: inv.plot_id, status: 'scheduled')
        .update(status: 'cancelled', updated_at: Time.now)
    end
    self
  end

  # Admin approves a pending payment → it hits the books now.
  def verify!(by:)
    return self if verification_status == 'verified'
    App.db.transaction do
      self.verification_status = 'verified'
      self.verified_by = by
      self.verified_at = Time.now
      save_changes
      apply_to_books!(invoice)
    end
    self
  end

  # Admin rejects a pending payment (no books were touched).
  def reject!(reason:, by:)
    update(verification_status: 'rejected', verified_by: by,
           verified_at: Time.now, reject_reason: reason)
    self
  end

  def validate
    super
    validates_presence [:client_id, :amount_paise]
    validates_includes MODES, :mode if mode
    validates_includes VERIFICATION, :verification_status if verification_status
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
      proof_url: proof_url,
      paid_on: paid_on,
      fy: fy,
      note: note,
      # verification + reconciliation (migration 0062)
      verification_status: verification_status || 'verified',
      verified_at: verified_at,
      reject_reason: reject_reason,
      reconciled: reconciled || false,
      reconciled_at: reconciled_at,
      bank_ref: bank_ref
    }
  end

  # Receipt payload for the member/admin receipt view + PDF. Carries the
  # association identity + verification so a printed receipt is self-describing.
  def as_receipt
    inv    = invoice
    client = App::Models::Client[client_id]
    cfg    = (client&.settings || {})
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
      period: inv&.period,
      # receipt improvements
      verification_status: verification_status || 'verified',
      verified_at: verified_at,
      balance_after: ((inv&.balance_paise || 0) / 100),
      fy: fy,
      association_name: client&.name,
      association_address: cfg['address'] || cfg.dig('association', 'address')
    }
  end
end
