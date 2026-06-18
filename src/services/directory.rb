class App::Services::Directory < App::Services::Base
  # Member-facing contact directory, derived from registered plots.
  def list
    ds = Plot.where(client_id: current_client_id, active: true)
             .exclude(owner_name: nil).order(:plot_no)
    if qs[:search].present?
      term = "%#{qs[:search]}%"
      ds = ds.where { Sequel.ilike(:owner_name, term) | Sequel.ilike(:plot_no, term) }
    end
    owners = ds.all.map do |p|
      { plot_no: p.plot_no, name: p.owner_name, phone: p.phone,
        phase: p.phase, membership: p.membership }
    end
    settings = Client[current_client_id]&.settings || {}
    staff = Staff.where(client_id: current_client_id, active: true).order(:name).all.map(&:as_pos)
    return_success(owners, committee: settings['committee'] || {}, staff: staff)
  end
end
