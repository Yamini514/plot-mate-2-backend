class App::Models::Client < Sequel::Model
  one_to_many :users, key: :client_id

  # Platform lifecycle (see migration 0038). `active` is the fast access gate;
  # `status` is the reporting lifecycle the super-admin dashboard counts on.
  STATUSES = %w[pending approved active modifications_requested suspended rejected archived].freeze

  def validate
    super
    validates_presence [:name]
    validates_includes STATUSES, :status if status
    validates_unique(:email) { |ds| ds.where(active: true) } if email
  end

  def status_label = status || (active ? 'active' : 'suspended')

  def as_pos
    as_json(only: %i[id name email active created_at]).merge(
      'status' => status_label, 'suspended_at' => suspended_at,
      'suspension_reason' => suspension_reason, 'approved_at' => approved_at
    )
  end
end
