class App::Models::Reminder < Sequel::Model
  CHANNELS = %w[whatsapp sms email].freeze
  STATUSES = %w[scheduled sent responded].freeze

  def validate
    super
    validates_presence [:client_id]
    validates_includes CHANNELS, :channel if channel
  end

  def as_pos
    { id: id, code: code, plot_no: plot_no, owner_name: owner_name,
      amount: (amount_paise || 0) / 100, channel: channel,
      scheduled_for: scheduled_for, status: status }
  end
end
