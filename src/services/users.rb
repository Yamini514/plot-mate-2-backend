class App::Services::Users < App::Services::Base
  def model = User

  def frontend_url
    ENV['FRONTEND_URL']
  end

  def list
    ds = scoped.order(Sequel.desc(:created_at))
    if qs[:search].present?
      term = "%#{qs[:search]}%"
      ds = ds.where { Sequel.ilike(:full_name, term) | Sequel.ilike(:email, term) }
    end
    ds = ds.where(role: qs[:role].to_i) if qs[:role].present?
    count = ds.count
    return_success(ds.offset(offset).limit(limit).all.map(&:as_pos),
                   total_pages: (count / page_size.to_f).ceil)
  end

  def get
    return_success(item.as_pos)
  end

  def create
    obj = model.new(data_for(:save))
    obj.client_id = current_client_id
    save(obj) { |u| return_success(u.as_pos) }
  end

  def update
    data = data_for(:save)
    item.set_fields(data, data.keys)
    save(item) { |u| return_success(u.as_pos) }
  end

  # --- current user --------------------------------------------------------
  def info
    return_success(App.cu.user_obj.as_pos)
  end

  # Self-service edit of the caller's own contact details. Deliberately narrow:
  # only the owner's display name and phone — email is the login identity and
  # role/plot are association-managed, so neither is touched here.
  def update_self
    u = App.cu.user_obj
    u.full_name = params[:full_name].to_s.strip if params[:full_name].present?
    u.phone_number = params[:phone_number] if params.key?(:phone_number)
    save(u) { return_success(u.as_pos) }
  end

  def update_password
    u = App.cu.user_obj
    unless u.authenticate(params[:current_password])
      return_errors!('Current password is incorrect', 400)
    end
    u.password = params[:new_password]
    save(u) { return_success('Password updated successfully') }
  end

  # --- password reset via OTP (public) -------------------------------------
  # Step 1: send a 6-digit code over the chosen channel (email | whatsapp). By
  # product decision this surfaces a clear error when the address isn't
  # registered (rather than the usual generic "if it exists…" reply), so plot
  # owners and guards know to check the email they actually signed up with.
  def forgot_password
    email = params[:email].to_s.strip.downcase
    return_errors!('Email is required', 400) if email.empty?
    channel = params[:channel].to_s == 'whatsapp' ? 'whatsapp' : 'email'

    user = model.where(email: email, active: true).first
    return_errors!('No account is registered with that email address.', 404) unless user

    if channel == 'whatsapp' && user.phone_number.to_s.strip.empty?
      return_errors!('No phone number is on file for this account — use email instead.', 422)
    end

    begin
      user.send_password_reset_otp(channel)
    rescue => e
      App.logger.error("OTP send failed (#{channel}): #{e.class}: #{e.message}")
      via = channel == 'whatsapp' ? 'WhatsApp' : 'email'
      return_errors!("We couldn’t send the code over #{via}: #{e.message}", 422)
    end

    msg = channel == 'whatsapp' ?
      'We’ve sent a 6-digit code to your registered WhatsApp number.' :
      'We’ve emailed you a 6-digit verification code.'
    return_success(msg)
  end

  # Step 2: verify the code. A valid code is exchanged for a single-use reset
  # token that authorises the final reset-password call.
  def verify_otp
    email = params[:email].to_s.strip.downcase
    code  = params[:otp].to_s.strip
    return_errors!('Email and code are required', 400) if email.empty? || code.empty?

    user = model.where(email: email, active: true).first
    return_errors!('No account is registered with that email address.', 404) unless user

    if user.reset_otp_valid?(code)
      return_success(token: user.consume_otp_issue_token!)
    else
      user.register_failed_otp_attempt!
      return_errors!('That code is invalid or has expired. Please request a new one.', 400)
    end
  end

  def validate_password_token
    user = model.where(reset_token: params[:token].to_s).first
    if user && !params[:token].to_s.empty? && user.reset_token_valid?
      return_success('Token is valid')
    else
      return_errors!('Invalid or expired token', 400)
    end
  end

  def reset_password
    token = params[:token].to_s
    new_password = params[:password].to_s
    return_errors!('Token and new password are required', 400) if token.empty? || new_password.empty?

    user = model.where(reset_token: token).first
    return_errors!('Invalid or expired token', 400) unless user && user.reset_token_valid?

    user.password = new_password
    user.reset_token = nil
    user.reset_sent_at = nil
    save(user) { return_success('Password has been reset') }
  end

  # Scope single-record lookups to the caller's tenant so get/update/delete
  # can never touch another association's users.
  def item(id = rp[:id])
    @item ||= scoped[id] || return_errors!('User not found', 404)
  end

  def self.fields
    { save: %i[full_name email password role phone_number active extras avatar_url] }
  end
end
