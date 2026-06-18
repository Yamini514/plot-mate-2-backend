class App::Models::Expense < Sequel::Model
  def validate
    super
    validates_presence [:client_id, :amount_paise]
  end

  def as_pos
    { id: id, code: code, date: date, description: description, category: category,
      vendor: vendor, amount: (amount_paise || 0) / 100, notes: notes }
  end
end
