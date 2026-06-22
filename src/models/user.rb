class App::Models::User < Sequel::Model
  # Canonical role enum (matches the three frontend personas).
  ROLES = { member: 0, guard: 1, admin: 2 }.freeze
  RESET_TOKEN_EXPIRY = 2 * 60 * 60 # 2 hours
  RESET_OTP_EXPIRY   = 10 * 60     # 10 minutes
  MAX_OTP_ATTEMPTS   = 5           # wrong guesses before the code is burned

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
  # Optional, but when supplied a phone must be exactly 10 digits.
  PHONE_RE = /\A\d{10}\z/

  def validate
    super
    validates_presence [:full_name, :email, :role, :client_id]
    validates_includes ROLES.values, :role
    validates_unique(:email) { |ds| ds.where(active: true) }
    if phone_number.to_s.strip != '' && phone_number.to_s.strip !~ PHONE_RE
      errors.add(:phone_number, 'must be a 10-digit number')
    end
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
    client = client_id ? App::Models::Client[client_id] : nil
    html = App::Mailer.branded_email(
      client: client,
      heading: 'Reset your password',
      intro: "Hello #{full_name}, we received a request to reset your PlotMate " \
             'password. Click the button below to choose a new one.',
      button_label: 'Reset password',
      button_url: reset_url,
      outro: 'This link expires in 2 hours.'
    )

    # Use the association's configured SMTP (Settings → Email); falls back to
    # the process-wide ENV config inside App::Mailer.
    App::Mailer.deliver(
      to: email,
      subject: 'Reset your PlotMate password',
      html_body: html,
      client: client
    )
  end

  # --- password reset via OTP ----------------------------------------------
  # Generates a fresh 6-digit code, resets the attempt counter and stamps the
  # send time so reset_otp_valid? can enforce the expiry window.
  def generate_reset_otp!
    self.reset_otp = format('%06d', SecureRandom.random_number(1_000_000))
    self.reset_otp_sent_at = Time.now
    self.reset_otp_attempts = 0
    save_changes
    reset_otp
  end

  # A code is valid only while it exists, is within the expiry window, hasn't
  # exhausted its attempt budget, and matches in constant time.
  def reset_otp_valid?(code)
    return false unless reset_otp && reset_otp_sent_at
    return false if (Time.now - reset_otp_sent_at) >= RESET_OTP_EXPIRY
    return false if reset_otp_attempts.to_i >= MAX_OTP_ATTEMPTS
    code = code.to_s
    return false unless code.length == reset_otp.length
    # Rack ships with Roda, so this constant-time compare is always available
    # (avoids depending on ActiveSupport::SecurityUtils being autoloaded).
    Rack::Utils.secure_compare(reset_otp, code)
  end

  # Count a wrong guess so a code can't be brute-forced indefinitely.
  def register_failed_otp_attempt!
    return unless reset_otp
    self.reset_otp_attempts = reset_otp_attempts.to_i + 1
    save_changes
  end

  # A verified OTP is exchanged for a single-use reset token: the existing
  # token columns then drive the standard reset-password step. The OTP is
  # cleared so it can't be replayed.
  def consume_otp_issue_token!
    self.reset_token = SecureRandom.urlsafe_base64
    self.reset_sent_at = Time.now
    self.reset_otp = nil
    self.reset_otp_sent_at = nil
    self.reset_otp_attempts = 0
    save_changes
    reset_token
  end

  # Deliver a fresh reset code over the chosen channel. 'whatsapp' messages the
  # owner's registered phone via the Cloud API template; anything else emails it.
  # Raises (via the messenger) on send failure so the caller can report why.
  def send_password_reset_otp(channel = 'email')
    otp = generate_reset_otp!
    client = client_id ? App::Models::Client[client_id] : nil

    if channel.to_s == 'whatsapp'
      raise 'No phone number is on file for this account.' if phone_number.to_s.strip.empty?
      # Per-association WhatsApp (Settings → WhatsApp); falls back to ENV.
      App::WhatsApp.send_otp(to: phone_number, code: otp, client: client)
      return
    end

    html = App::Mailer.branded_email(
      client: client,
      heading: 'Your password reset code',
      intro: "Hello #{full_name}, use the verification code below to reset your " \
             'PlotMate password.',
      code: otp,
      outro: 'This code expires in 10 minutes. Never share it with anyone — ' \
             'PlotMate staff will never ask you for it.'
    )

    # Per-association SMTP (Settings → Email); falls back to ENV in App::Mailer.
    App::Mailer.deliver(
      to: email,
      subject: "#{otp} is your PlotMate password reset code",
      html_body: html,
      client: client
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
