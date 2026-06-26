class App::Services::Refunds < App::Services::Base
  # Refunds / credit reversals against a recorded payment. Approval posts a
  # treasury DEBIT (mirror of the credit a payment posts), so the books stay
  # balanced. Tenant-scoped.
  def model = Refund

  def list
    ds = scoped.order(Sequel.desc(:created_at))
    ds = ds.where(status: qs[:status]) if qs[:status].present? && qs[:status] != 'all'
    total = ds.count
    return_success(ds.offset(offset).limit(limit).all.map(&:as_pos),
                   counts: counts_by_status, **pagination_meta(total))
  end

  def get = return_success(item.as_pos)

  def create
    pmt = Payment[client_id: current_client_id, id: params[:payment_id].to_i] ||
          return_errors!('Payment not found', 404)
    amount_paise = (params[:amount].to_f * 100).round
    validate!(
      'amount' => App::Validate.number(params[:amount], positive: true, label: 'Amount'),
      'reason' => App::Validate.text(params[:reason], min: 3, max: 500)
    )
    return_errors!('Refund exceeds the payment amount', 422) if amount_paise > pmt.amount_paise.to_i
    return_errors!('Can only refund a verified payment', 422) unless pmt.verification_status == 'verified'

    obj = Refund.new(
      client_id: current_client_id, payment_id: pmt.id, plot_id: pmt.plot_id,
      amount_paise: amount_paise, reason: params[:reason],
      method: Refund::METHODS.include?(params[:method].to_s) ? params[:method] : 'bank',
      status: 'pending', code: next_code, created_by: App.cu.id
    )
    save(obj) do |rf|
      App::Audit.record('refund.create', entity: rf, client_id: rf.client_id,
                        summary: "Refund #{rf.code} requested (#{format_currency(amount_paise)})",
                        meta: { payment_id: pmt.id })
      return_success(rf.as_pos)
    end
  end

  def approve
    return_errors!('Only a pending refund can be approved', 422) unless item.status == 'pending'
    App.db.transaction do
      item.set(status: 'approved', approved_by: App.cu.id, approved_at: Time.now)
      item.save_changes
      # Treasury debit so the ledger reflects money going back out.
      Transaction.create(client_id: item.client_id, direction: 'debit',
                         category: 'refund', amount_paise: item.amount_paise,
                         reference: item.code, note: "Refund for payment ##{item.payment_id}",
                         occurred_on: Date.today)
    end
    App::Audit.record('refund.approve', entity: item, client_id: item.client_id,
                      summary: "Approved refund #{item.code}")
    return_success(item.as_pos)
  end

  def mark_paid
    return_errors!('Approve the refund first', 422) unless item.status == 'approved'
    item.set(status: 'paid', updated_by: App.cu.id)
    save(item) do |rf|
      App::Audit.record('refund.paid', entity: rf, client_id: rf.client_id,
                        summary: "Marked refund #{rf.code} paid")
      return_success(rf.as_pos)
    end
  end

  def reject
    return_errors!('Only a pending refund can be rejected', 422) unless item.status == 'pending'
    item.set(status: 'rejected', approved_by: App.cu.id, approved_at: Time.now)
    save(item) do |rf|
      App::Audit.record('refund.reject', entity: rf, client_id: rf.client_id,
                        summary: "Rejected refund #{rf.code}", meta: { reason: params[:reason] })
      return_success(rf.as_pos)
    end
  end

  def item(id = rp[:id]) = (@item ||= scoped[id] || return_errors!('Refund not found', 404))

  private

  def counts_by_status
    c = scoped.group_and_count(:status).all
              .each_with_object({}) { |r, h| h[r[:status]] = r[:count] }
    c['all'] = scoped.count
    c
  end

  def next_code
    year = Date.today.year
    seq = scoped.where(Sequel.like(:code, "REF-#{year}-%")).count + 1
    "REF-#{year}-#{format('%04d', seq)}"
  end

  def self.fields
    { save: %i[payment_id amount_paise reason method] }
  end
end
