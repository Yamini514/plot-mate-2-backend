class App::Models::Client < Sequel::Model
  one_to_many :users, key: :client_id

  def validate
    super
    validates_presence [:name]
    validates_unique(:email) { |ds| ds.where(active: true) } if email
  end

  def as_pos
    as_json(only: %i[id name email active created_at])
  end
end
