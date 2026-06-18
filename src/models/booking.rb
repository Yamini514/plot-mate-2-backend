class App::Models::Booking < Sequel::Model
  STATUSES = %w[pending confirmed cancelled].freeze

  def validate
    super
    validates_presence [:client_id, :amenity_id]
    validates_includes STATUSES, :status if status
  end

  def as_pos
    { id: id, code: code, amenity_id: amenity_id, amenity_name: amenity_name,
      booked_by: booked_by, plot_no: plot_no, date: date, slot: slot,
      status: status, amount: (amount_paise || 0) / 100 }
  end
end
