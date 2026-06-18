class App::Models::User < Sequel::Model
  # Canonical role enum (matches the three frontend personas).
  ROLES = { member: 0, guard: 1, admin: 2 }.freeze
  RESET_TOKEN_EXPIRY = 2 * 60 * 60 # 2 hours

  def member? = role == ROLES[:member]
  def guard?  = role == ROLES[:guard]
  def admin?  = role == ROLES[:admin]

  def role_name
    ROLES.key(role)&.to_s || 'unknown'
  end

  # --- password (BCrypt) ---------------------------------------------------
  def password
    @password ||= BCrypt::Password.new(encoded_password) if encoded_password
  end

  def password=(new_password)
    return if new_password.to_s.empty?
    @password = BCrypt::Password.create(new_password)
    self.encoded_password = @password.to_s
  end

  def authenticate(plain)
    !!password && password == plain.to_s
  rescue BCrypt::Errors::InvalidHash
    false
  end

  # --- validations ---------------------------------------------------------
  def validate
    super
    validates_presence [:full_name, :email, :role, :client_id]
    validates_includes ROLES.values, :role
    validates_unique(:email) { |ds| ds.where(active: true) }
  end

  # --- password reset ------------------------------------------------------
  def generate_reset_token!
    self.reset_token = SecureRandom.urlsafe_base64
    self.reset_sent_at = Time.now
    save_changes
    reset_token
  end

  def reset_token_valid?
    reset_sent_at && (Time.now - reset_sent_at) < RESET_TOKEN_EXPIRY
  end

  def send_password_reset_email(base_url)
    generate_reset_token!
    reset_url = "#{base_url}/reset-password?token=#{CGI.escape(reset_token)}"
    html = "<p>Hello #{full_name},</p>" \
           "<p>We received a request to reset your password. " \
           "<a href=\"#{reset_url}\">Click here to reset it</a>. " \
           "This link expires in 2 hours.</p>" \
           "<p>If you didn't request this, you can ignore this email.</p>"

    # Use the association's configured SMTP (Settings → Email); falls back to
    # the process-wide ENV config inside App::Mailer.
    App::Mailer.deliver(
      to: email,
      subject: 'Reset your PlotMate password',
      html_body: html,
      client: client_id ? App::Models::Client[client_id] : nil
    )
  end

  # --- serialization -------------------------------------------------------
  # Public shape returned to the frontend. Mirrors the session object the
  # Next app expects (name/email/role/title/plotNo/guardId).
  def as_pos
    {
      id: id,
      full_name: full_name,
      email: email,
      phone_number: phone_number,
      role: role,
      role_name: role_name,
      active: active,
      avatar_url: avatar_url,
      title: extras&.dig('title'),
      plot_no: extras&.dig('plot_no'),
      guard_id: extras&.dig('guard_id'),
      # Optional operational fields for the guard profile (admin-set, in extras).
      gate: extras&.dig('gate'),
      agency: extras&.dig('agency'),
      supervisor_name: extras&.dig('supervisor_name'),
      supervisor_phone: extras&.dig('supervisor_phone'),
      last_logged_in_at: last_logged_in_at,
      created_at: created_at
    }
  end
end
