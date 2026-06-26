class App::Models::AnnouncementAck < Sequel::Model
  def validate
    super
    validates_presence [:client_id, :announcement_id]
  end

  def as_pos
    { id: id, user_id: user_id, plot_no: plot_no, name: name, acked_at: acked_at }
  end
end
