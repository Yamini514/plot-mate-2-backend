class App::Models::Invite < Sequel::Model
  STATUSES = %w[pending accepted revoked expired].freeze
  DEFAULT_TTL = 14 * 24 * 60 * 60 # 14 days

  def validate
    super
    validates_presence [:client_id, :token]
    validates_includes STATUSES, :status if status
  end

  def pending?  = status == 'pending'
  def expired?  = expires_at && Time.now > expires_at
  # Usable = still pending and within its window.
  def usable?   = pending? && !expired?

  def role_name = App::Models::User::ROLES.key(role)&.to_s || 'member'

  # Shape for the admin list (never leaks the raw token except on creation).
  def as_pos(with_token: false)
    base = { id: id, code: code, email: email, full_name: full_name,
             role: role, role_name: role_name, plot_id: plot_id,
             status: expired? ? 'expired' : status, user_id: user_id,
             expires_at: expires_at, accepted_at: accepted_at, created_at: created_at }
    base[:token] = token if with_token
    base
  end

  # Public shape shown on the accept page (no internal ids).
  def as_public
    { code: code, email: email, full_name: full_name, role_name: role_name,
      plot_id: plot_id, status: expired? ? 'expired' : status }
  end
end
