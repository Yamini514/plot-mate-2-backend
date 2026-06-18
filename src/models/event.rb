class App::Models::Event < Sequel::Model
  TYPES = %w[meeting maintenance social].freeze

  def validate
    super
    validates_presence [:client_id, :title]
  end

  # Toggle a user's RSVP; returns :added or :removed. Count kept in sync.
  def toggle_rsvp!(user_id)
    existing = App.db[:event_rsvps].where(event_id: id, user_id: user_id)
    App.db.transaction do
      if existing.count.positive?
        existing.delete
        self.rsvp_count = [(rsvp_count || 0) - 1, 0].max
        save_changes
        :removed
      else
        App.db[:event_rsvps].insert(client_id: client_id, event_id: id, user_id: user_id)
        self.rsvp_count = (rsvp_count || 0) + 1
        save_changes
        :added
      end
    end
  end

  def as_pos(user_id = nil)
    {
      id: id, code: code, title: title, description: description, date: date,
      time: time, location: location, type: type, rsvp_count: rsvp_count,
      rsvped: user_id ? App.db[:event_rsvps].where(event_id: id, user_id: user_id).count.positive? : nil
    }
  end
end
