class App::Models::LostFoundItem < Sequel::Model
  STATUSES = %w[open claimed closed].freeze

  def validate
    super
    validates_presence [:client_id, :title]
    validates_includes STATUSES, :status if status
  end

  def as_pos
    { id: id, code: code, title: title, description: description, photo_url: photo_url,
      found_location: found_location, status: status, claimant_name: claimant_name,
      claimant_phone: claimant_phone, created_at: created_at }
  end
end
