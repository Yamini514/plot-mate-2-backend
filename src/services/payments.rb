class App::Services::Payments < App::Services::Base
  def model = Payment

  def list
    ds = scoped.order(Sequel.desc(:paid_on), Sequel.desc(:id))
    if qs[:search].present?
      term = "%#{qs[:search]}%"
      ds = ds.where do
        Sequel.ilike(:owner_name, term) | Sequel.ilike(:property, term) |
          Sequel.ilike(:number, term) | Sequel.ilike(:reference, term)
      end
    end
    count = ds.count
    return_success(ds.offset(offset).limit(limit).all.map(&:as_pos),
                   total_pages: (count / page_size.to_f).ceil)
  end

  def get
    return_success(item.as_pos)
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
      note: params[:note]
    )
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

  def parse_date(val)
    val.present? ? Date.parse(val.to_s) : nil
  rescue ArgumentError
    nil
  end
end
