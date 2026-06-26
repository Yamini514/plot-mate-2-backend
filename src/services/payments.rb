class App::Services::Payments < App::Services::Base
  def model = Payment

  def list
    ds = scoped.order(Sequel.desc(:paid_on), Sequel.desc(:id))
    ds = ds.where(verification_status: qs[:verification]) if qs[:verification].present? && qs[:verification] != 'all'
    ds = ds.where(reconciled: qs[:reconciled] == 'true') if qs[:reconciled].present?
    if qs[:search].present?
      term = "%#{qs[:search]}%"
      ds = ds.where do
        Sequel.ilike(:owner_name, term) | Sequel.ilike(:property, term) |
          Sequel.ilike(:number, term) | Sequel.ilike(:reference, term)
      end
    end
    total = ds.count
    return_success(ds.offset(offset).limit(limit).all.map(&:as_pos),
                   counts: verification_counts, **pagination_meta(total))
  end

  def get
    return_success(item.as_pos)
  end

  # Approve a pending (member-reported) payment → it hits the books now.
  def verify
    return_errors!('Payment is not pending verification', 422) unless item.verification_status == 'pending'
    item.verify!(by: App.cu.id)
    App::Audit.record('payment.verify', entity: item, client_id: item.client_id,
                      summary: "Verified payment #{item.number} (#{format_currency(item.amount_paise)})")
    App::Notify.create(user_id: item.submitted_by_user_id, client_id: item.client_id, kind: 'payment',
                       title: 'Payment verified',
                       body: "Your payment #{item.number} (#{format_currency(item.amount_paise)}) was verified.",
                       link: '/member/billing', entity: item)
    return_success(item.as_pos)
  rescue => e
    App.logger.error("Verify payment error: #{e.message}")
    return_errors!("Unable to verify: #{e.message}", 400)
  end

  def reject
    return_errors!('Payment is not pending verification', 422) unless item.verification_status == 'pending'
    validate!('reason' => App::Validate.text(params[:reason], min: 3, max: 500))
    item.reject!(reason: params[:reason], by: App.cu.id)
    App::Audit.record('payment.reject', entity: item, client_id: item.client_id,
                      summary: "Rejected payment #{item.number}", meta: { reason: params[:reason] })
    App::Notify.create(user_id: item.submitted_by_user_id, client_id: item.client_id, kind: 'payment',
                       title: 'Payment could not be verified',
                       body: "Your payment #{item.number} was rejected: #{params[:reason]}",
                       link: '/member/billing', entity: item)
    return_success(item.as_pos)
  end

  # Mark a payment as matched against the bank statement (reconciliation).
  def reconcile
    on = params.key?(:reconciled) ? !!params[:reconciled] : true
    item.set(reconciled: on, reconciled_at: on ? Time.now : nil,
             bank_ref: params[:bank_ref].presence)
    save(item) do |p|
      App::Audit.record('payment.reconcile', entity: p, client_id: p.client_id,
                        summary: "#{on ? 'Reconciled' : 'Unreconciled'} payment #{p.number}")
      return_success(p.as_pos)
    end
  end

  # Record a payment against an invoice (partial supported).
  def create
    inv = Invoice[client_id: current_client_id, id: params[:invoice_id]] ||
          return_errors!('Invoice not found', 404)
    amount_paise = (params[:amount].to_f * 100).round
    return_errors!('Amount must be positive', 400) if amount_paise <= 0
    return_errors!('Amount exceeds balance', 400)  if amount_paise > inv.balance_paise.to_i

    pmt = Payment.record!(
      invoice: inv, amount_paise: amount_paise,
      mode: params[:mode].presence || 'cash',
      reference: params[:reference], paid_on: parse_date(params[:paid_on]),
      note: params[:note], proof_url: params[:proof_url].presence,
      proof_key: params[:proof_key].presence
    )
    # NB: clearing dues also cancels the plot's scheduled reminders — handled
    # centrally inside Payment.record! so member-pay and Stripe paths get it too.
    App::Audit.record('payment.record', entity: pmt, client_id: pmt.client_id,
                      summary: "Recorded payment #{pmt.number} (#{format_currency(amount_paise)}) for #{inv.number}")
    return_success(pmt.as_pos.merge(invoice: inv.as_pos))
  rescue => e
    App.logger.error("Record payment error: #{e.message}")
    App.logger.error(e.backtrace.join("\n"))
    return_errors!("Unable to record payment: #{e.message}", 400)
  end

  # Printable receipt for a payment.
  def receipt
    return_success(item.as_receipt)
  end

  def item(id = rp[:id])
    @item ||= scoped[id] || return_errors!('Payment not found', 404)
  end

  private

  def verification_counts
    base = scoped
    { all: base.count,
      pending:  base.where(verification_status: 'pending').count,
      verified: base.where(verification_status: 'verified').count,
      rejected: base.where(verification_status: 'rejected').count,
      unreconciled: base.where(verification_status: 'verified').where(reconciled: [false, nil]).count }
  end

  def parse_date(val)
    val.present? ? Date.parse(val.to_s) : nil
  rescue ArgumentError
    nil
  end
end
