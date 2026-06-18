class App::Models::Photo < Sequel::Model
  def validate
    super
    validates_presence [:client_id]
  end

  def as_pos
    { id: id, code: code, url: url, caption: caption, category: category, date: date }
  end
end
