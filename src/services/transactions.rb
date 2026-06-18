class App::Services::Transactions < App::Services::Base
  def model = Transaction

  # Treasury ledger (read-only here; entries are posted by payment recording).
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
end
