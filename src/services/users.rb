class App::Services::Users < App::Services::Base
  def model = User

  def frontend_url
    ENV['FRONTEND_URL'] || 'http://localhost:3000'
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

  # --- password reset (public) ---------------------------------------------
  def forgot_password
    email = params[:email].to_s.strip.downcase
    return_errors!('Email is required', 400) if email.empty?

    user = model.where(email: email, active: true).first
    user&.send_password_reset_email(frontend_url)
    # Don't leak whether the email exists.
    return_success('If that email is registered, a reset link has been sent.')
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
    { save: %i[full_name email password role phone_number active extras] }
  end
end
