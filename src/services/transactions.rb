class App::Services::Transactions < App::Services::Base
  def model = Transaction

  # Treasury ledger. Entries are posted automatically by payment recording
  # (credits) and expenses (debits); admins can also add manual funds here.
  def list
    ds = scoped.order(Sequel.desc(:occurred_on), Sequel.desc(:id))
    ds = ds.where(direction: qs[:direction]) if qs[:direction].present?
    count = ds.count

    credits = scoped.where(direction: 'credit').sum(:amount_paise) || 0
    debits  = scoped.where(direction: 'debit').sum(:amount_paise) || 0

    return_success(
      ds.offset(offset).limit(limit).all.map(&:as_pos),
      total_pages: (count / page_size.to_f).ceil,
      balance: { income: credits / 100, expense: debits / 100, net: (credits - debits) / 100 }
    )
  end

  # Manually add funds to the treasury (donation, interest, opening balance,
  # cash maintenance collected outside billing, etc.). Posts a credit entry.
  def add_funds
    amount_paise = (params[:amount].to_f * 100).round
    return_errors!('Amount must be positive', 400) if amount_paise <= 0
    direction = params[:direction] == 'debit' ? 'debit' : 'credit'

    obj = Transaction.new(
      client_id:    current_client_id,
      direction:    direction,
      category:     params[:category].presence || 'other_income',
      amount_paise: amount_paise,
      reference:    params[:reference].presence || next_reference(direction),
      note:         params[:note],
      occurred_on:  parse_date(params[:occurred_on]) || Date.today
    )
    save(obj) { |t| return_success(t.as_pos) }
  end

  # Reverse a manual ledger entry. Entries posted by billing (payment/invoice
  # linked) are immutable here — they must be unwound from their source module.
  def delete
    if item.payment_id || item.invoice_id
      return_errors!('This entry was posted by billing and cannot be deleted here.', 422)
    end
    res = item.delete
    res ? return_success(item.as_pos) : return_errors!('Unable to delete')
  end

  def item(id = rp[:id]) = (@item ||= scoped[id] || return_errors!('Entry not found', 404))

  private

  def next_reference(direction)
    prefix = direction == 'credit' ? 'FND' : 'ADJ'
    "#{prefix}-#{scoped.where(direction: direction).count + 1}"
  end

  def parse_date(val)
    val.present? ? Date.parse(val.to_s) : nil
  rescue ArgumentError
    nil
  end
end
