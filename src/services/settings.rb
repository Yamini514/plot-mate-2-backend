class App::Services::Settings < App::Services::Base
  # Association config stored on the client (rate, bank, committee, etc.).
  def show
    c = Client[current_client_id]
    return_success((c.settings || {}).merge(name: c.name, email: c.email))
  end

  def update
    c = Client[current_client_id]
    incoming = (params || {}).reject { |k, _| %w[name email].include?(k.to_s) }
    c.settings = (c.settings || {}).merge(incoming)
    c.name  = params[:name]  if params[:name].present?
    c.email = params[:email] if params[:email].present?
    save(c) { return_success((c.settings || {}).merge(name: c.name, email: c.email)) }
  end
end
