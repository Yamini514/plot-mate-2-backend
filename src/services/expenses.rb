class App::Services::Expenses < App::Services::Base
  def model = Expense

  def list
    ds = scoped.order(Sequel.desc(:date), Sequel.desc(:id))
    ds = ds.where(category: qs[:category]) if qs[:category].present? && qs[:category] != 'all'
    return_success(ds.all.map(&:as_pos))
  end

  # Recording an expense also posts a debit to the treasury ledger.
  def create
    d = data_for(:save)
    d['amount_paise'] = (d.delete('amount').to_f * 100).round if d.key?('amount')
    obj = model.new(d)
    obj.client_id = current_client_id
    obj.code ||= "EXP-#{216 + scoped.count}"
    obj.date ||= Date.today
    App.db.transaction do
      save(obj) do |e|
        Transaction.create(
          client_id: e.client_id, direction: 'debit', category: e.category || 'expense',
          amount_paise: e.amount_paise, reference: e.code, note: e.description, occurred_on: e.date
        )
        App::Audit.record('expense.create', entity: e, client_id: e.client_id,
                          summary: "Recorded expense #{e.code} (#{format_currency(e.amount_paise)})")
        return_success(e.as_pos)
      end
    end
  end

  # Editing an expense also re-syncs the matching treasury ledger debit so the
  # balance and reports stay correct.
  def update
    d = data_for(:save)
    d['amount_paise'] = (d.delete('amount').to_f * 100).round if d.key?('amount')
    App.db.transaction do
      item.set_fields(d, d.keys)
      save(item) do |e|
        txn = Transaction.where(client_id: e.client_id, reference: e.code).first
        txn&.update(
          category: e.category || 'expense', amount_paise: e.amount_paise,
          note: e.description, occurred_on: e.date
        )
        return_success(e.as_pos)
      end
    end
  end

  # Removing an expense also reverses its treasury ledger debit.
  def delete
    App.db.transaction do
      Transaction.where(client_id: item.client_id, reference: item.code).delete
      res = item.delete
      res ? return_success(item.as_pos) : return_errors!('Unable to delete')
    end
  rescue => e
    App.logger.error(e.message)
    return_errors!(e.message, 400)
  end

  # Spend grouped by category (for the treasury pie chart).
  def by_category
    rows = scoped.all.group_by(&:category)
    return_success(rows.map { |cat, list| { name: cat, value: list.sum { |e| e.amount_paise } / 100 } })
  end

  def item(id = rp[:id]) = (@item ||= scoped[id] || return_errors!('Expense not found', 404))

  def self.fields
    { save: %i[date description category vendor amount notes] }
  end
end
