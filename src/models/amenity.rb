class App::Models::Amenity < Sequel::Model
  STATUSES = %w[available maintenance].freeze

  def validate
    super
    validates_presence [:client_id, :name]
  end

  def as_pos
    { id: id, code: code, name: name, description: description, capacity: capacity,
      hourly_rate: (hourly_rate_paise || 0) / 100, icon: icon, status: status }
  end
end
