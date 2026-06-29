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

  # --- committee / staff management (RBAC) -----------------------------------
  # Every venture admin-role user (owner-admin + committee/staff), with their
  # assigned role name. The owner-admin (role_id nil) is flagged unrestricted.
  def committee_list
    rows = scoped.where(role: User::ROLES[:admin]).order(Sequel.desc(:created_at)).all
    role_names = App::Models::Role.where(client_id: current_client_id)
                                  .select_hash(:id, :name)
    return_success(rows.map { |u|
      u.as_pos.merge(role_name_label: u.role_id ? role_names[u.role_id] : 'Venture Admin (full access)',
                     unrestricted: u.role_id.nil?)
    })
  end

  # Create a committee member / staff login: a venture admin (role 2) gated by a
  # custom role's permissions. Returns a one-time temp password.
  def create_committee
    role = App::Models::Role[client_id: current_client_id, id: params[:role_id]] ||
           return_errors!('Pick a valid role', 422)
    validate!(
      'full_name' => App::Validate.text(params[:full_name], min: 2, max: 120, label: 'Name'),
      'email'     => App::Validate.email(params[:email]),
      'phone_number' => App::Validate.phone(params[:phone_number])
    )
    temp = SecureRandom.alphanumeric(10)
    u = model.new(
      client_id: current_client_id, full_name: params[:full_name].to_s.strip,
      email: params[:email].to_s.strip.downcase, phone_number: params[:phone_number].presence,
      role: User::ROLES[:admin], role_id: role.id, active: true,
      extras: { 'title' => role.name }
    )
    u.password = temp
    save(u) do |row|
      App::Audit.record('committee.create', entity: row, client_id: current_client_id,
                        summary: "Created committee member #{row.full_name} as #{role.name}",
                        meta: { role_id: role.id, role: role.name })
      return_success(row.as_pos.merge(temp_password: temp))
    end
  end

  # Transfer / change a committee member's role (re-point role_id). Owner-admin
  # (role_id nil) can't be demoted here — guard against self-lockout.
  def assign_role
    return_errors!("You can't change your own role", 422) if item.id == App.cu.id
    role = App::Models::Role[client_id: current_client_id, id: params[:role_id]] ||
           return_errors!('Pick a valid role', 422)
    item.set(role_id: role.id)
    item.extras = (item.extras || {}).merge('title' => role.name)
    save(item) do |u|
      App::Audit.record('user.assign', entity: u, client_id: current_client_id,
                        summary: "Assigned #{u.full_name} to role #{role.name}", meta: { role_id: role.id })
      return_success(u.as_pos)
    end
  end

  # Hard-lock an account (separate from deactivate): blocks login + ends session.
  def lock
    return_errors!("You can't lock your own account", 422) if item.id == App.cu.id
    item.set(locked_at: Time.now, lock_reason: params[:reason], current_session_id: nil)
    save(item) do |u|
      App::Audit.record('account.lock', entity: u, client_id: current_client_id,
                        summary: "Locked #{u.full_name}", meta: { reason: params[:reason] })
      return_success(u.as_pos)
    end
  end

  def unlock
    item.set(locked_at: nil, lock_reason: nil)
    save(item) do |u|
      App::Audit.record('account.unlock', entity: u, client_id: current_client_id, summary: "Unlocked #{u.full_name}")
      return_success(u.as_pos)
    end
  end

  # A user's login history (most recent first).
  def login_history
    return_success([]) unless App::Models.const_defined?(:LoginEvent)
    rows = App::Models::LoginEvent.where(user_id: item.id).order(Sequel.desc(:created_at)).limit(50).all
    return_success(rows.map(&:as_pos))
  end

  # Admin resets a venture user's password → one-time temp password.
  def admin_reset_password
    temp = SecureRandom.alphanumeric(10)
    item.password = temp
    item.current_session_id = nil
    save(item) do |u|
      App::Audit.record('password.reset', entity: u, client_id: current_client_id,
                        summary: "Reset password for #{u.full_name}")
      return_success(email: u.email, temp_password: temp)
    end
  end

  # The caller's effective RBAC permissions. `all: true` for the venture
  # owner-admin / super admin (every permission); otherwise the explicit list
  # from their assigned committee role. Drives permission-based menus/buttons.
  def my_permissions
    u = App.cu.user_obj
    perms = App::Permissions.for(u)
    if perms == App::Permissions::ALL
      return_success(all: true, permissions: App::Models::Role::PERMISSIONS)
    else
      return_success(all: false, permissions: perms)
    end
  end

  # Self-service edit of the caller's own contact details. Deliberately narrow:
  # only the owner's display name and phone — email is the login identity and
  # role/plot are association-managed, so neither is touched here.
  def update_self
    u = App.cu.user_obj
    u.full_name = params[:full_name].to_s.strip if params[:full_name].present?
    u.phone_number = params[:phone_number] if params.key?(:phone_number)
    u.avatar_url = params[:avatar_url] if params.key?(:avatar_url)
    # Structured owner contacts (migration 0063) — arrays of small hashes.
    u.family_members     = Array(params[:family_members])     if params.key?(:family_members)
    u.emergency_contacts = Array(params[:emergency_contacts]) if params.key?(:emergency_contacts)
    u.nominees           = Array(params[:nominees])           if params.key?(:nominees)
    # Communication / language / privacy preferences live in extras (no migration).
    if params.key?(:communication_prefs)
      u.extras = (u.extras || {}).merge('comm_prefs' => params[:communication_prefs])
    end
    # Vendor company details + emergency contact (extras, no migration).
    u.extras = (u.extras || {}).merge('company' => params[:company]) if params.key?(:company)
    u.extras = (u.extras || {}).merge('emergency_contact' => params[:emergency_contact]) if params.key?(:emergency_contact)
    save(u) do
      App::Audit.record('profile.update', entity: u, client_id: u.client_id,
                        summary: "#{u.full_name} updated their profile")
      return_success(u.as_pos)
    end
  end

  # Admin deactivate/reactivate of a venture user (block = active:false + reason).
  def deactivate
    return_errors!("You can't deactivate your own account", 422) if item.id == App.cu.id
    validate!('reason' => App::Validate.text(params[:reason], min: 3, max: 500))
    item.set(active: false, blocked_at: Time.now, blocked_by: App.cu.id,
             block_reason: params[:reason], current_session_id: nil)
    save(item) do |u|
      App::Audit.record('user.deactivate', entity: u, client_id: u.client_id,
                        summary: "Deactivated #{u.full_name}", meta: { reason: params[:reason] })
      return_success(u.as_pos)
    end
  end

  def activate
    item.set(active: true, blocked_at: nil, blocked_by: nil, block_reason: nil)
    save(item) do |u|
      App::Audit.record('user.activate', entity: u, client_id: u.client_id,
                        summary: "Reactivated #{u.full_name}")
      return_success(u.as_pos)
    end
  end

  def update_password
    u = App.cu.user_obj
    unless u.authenticate(params[:current_password])
      return_errors!('Current password is incorrect', 400)
    end
    validate!('new_password' => App::Validate.password(params[:new_password]))
    u.password = params[:new_password]
    save(u) do
      App::Audit.record('password.change', entity: u, client_id: u.client_id,
                        summary: "#{u.full_name} changed their password")
      return_success('Password updated successfully')
    end
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

    validate!('password' => App::Validate.password(new_password))
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
