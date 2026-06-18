class App::Services::Session < App::Services::Base
  def login
    user = User.find(email: params[:email].to_s.strip.downcase, active: true)

    unless user && user.authenticate(params[:password])
      return_errors!('Invalid email or password', 401)
    end

    user.last_logged_in_at = Time.now
    user.current_session_id = CurrentUser.encoded_token(user)
    user.save_changes

    return_success(user.as_pos.merge(token: user.current_session_id))
  rescue => e
    App.logger.error("Login error: #{e.message}")
    App.logger.error(e.backtrace.join("\n"))
    return_errors!('Unable to sign in. Please try again.', 500)
  end
end
