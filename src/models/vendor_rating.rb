class App::Models::VendorRating < Sequel::Model
  def validate
    super
    validates_presence [:client_id, :staff_id, :score]
    errors.add(:score, 'must be 1–5') unless (1..5).include?(score.to_i)
  end

  def as_pos
    { id: id, staff_id: staff_id, ticket_id: ticket_id, score: score,
      note: note, created_at: created_at }
  end
end
