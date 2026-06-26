class App::Services::Session < App::Services::Base
  def login
    user = User.find(email: params[:email].to_s.strip.downcase, active: true)

    unless user && user.authenticate(params[:password])
      return_errors!('Invalid email or password', 401)
    end

    user.last_logged_in_at = Time.now
    user.current_session_id = CurrentUser.encoded_token(user)
    user.save_changes

    # Login activity in the audit trail. Pass the actor explicitly — this request
    # isn't token-authenticated yet, so App::Audit can't infer the current user.
    App::Audit.record('user.login', entity: user, client_id: user.client_id,
                      summary: "#{user.full_name} signed in (#{user.role_name})", actor: user)

    # Guards clock in for a shift the moment they sign in — this is the source
    # of the login/logout timings the admin sees and the early-clock-out check.
    open_shift!(user) if user.guard?

    return_success(user.as_pos.merge(token: user.current_session_id))
  rescue => e
    App.logger.error("Login error: #{e.message}")
    App.logger.error(e.backtrace.join("\n"))
    return_errors!('Unable to sign in. Please try again.', 500)
  end

  # Ends the caller's session: closes an open guard shift (flagging an early
  # clock-out) and clears the single-session token so the JWT can't be reused.
  # The session token is always cleared even if shift bookkeeping fails — a
  # logout must never leave a reusable session behind.
  def logout
    user = App.cu.user_obj
    return return_success(ended: false) unless user

    early = user.guard? ? close_open_shift!(user) : false

    user.current_session_id = nil
    user.save_changes
    return_success(ended: true, ended_early: !!early)
  rescue => e
    App.logger.error("Logout error: #{e.message}")
    return_success(ended: false)
  end

  private

  # Is the shift_sessions table available? (Defined only once migrated — see
  # the model.) Lets login/logout no-op cleanly before the migration runs.
  def shift_tracking? = App::Models.const_defined?(:ShiftSession)

  # Open a fresh shift for a guard, defensively closing any session that was
  # left hanging (e.g. the app closed without a clean sign-out). Never raises.
  def open_shift!(user)
    return unless shift_tracking?
    now = Time.now
    ShiftSession
      .where(user_id: user.id, ended_at: nil)
      .update(ended_at: now, end_reason: 'superseded', updated_at: now)

    ShiftSession.create(
      client_id:     user.client_id,
      user_id:       user.id,
      shift_name:    ShiftSession.shift_for(now)[:name],
      started_at:    now,
      scheduled_end: ShiftSession.scheduled_end_for(now)
    )
  rescue => e
    App.logger.error("open_shift! error: #{e.message}")
  end

  # Close the guard's open shift, returning whether it was an early clock-out.
  # Never raises — a bookkeeping failure must not block sign-out.
  def close_open_shift!(user)
    return false unless shift_tracking?
    now   = Time.now
    shift = ShiftSession
            .where(user_id: user.id, ended_at: nil)
            .order(Sequel.desc(:started_at)).first
    return false unless shift

    early = !!(shift.scheduled_end && now < shift.scheduled_end)
    shift.set(ended_at: now, ended_early: early, end_reason: 'logout')
    shift.save_changes
    early
  rescue => e
    App.logger.error("close_open_shift! error: #{e.message}")
    false
  end
end
