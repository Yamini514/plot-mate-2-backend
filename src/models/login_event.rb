class App::Models::LoginEvent < Sequel::Model
  def as_pos
    { id: id, ip: ip, user_agent: user_agent, success: success, created_at: created_at }
  end
end
