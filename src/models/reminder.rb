class App::Models::Reminder < Sequel::Model
  # SMS retired — reminders go out over WhatsApp + email only.
  CHANNELS = %w[whatsapp email].freeze
  # 'cancelled' is set automatically when the owner clears their dues.
  STATUSES = %w[scheduled sent responded cancelled].freeze

  def validate
    super
    validates_presence [:client_id]
    validates_includes CHANNELS, :channel if channel
  end

  def as_pos
    { id: id, code: code, plot_no: plot_no, owner_name: owner_name,
      amount: (amount_paise || 0) / 100, channel: channel,
      scheduled_for: scheduled_for, sent_at: sent_at, status: status }
  end
end
