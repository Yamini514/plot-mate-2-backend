class App::Services::Ventures < App::Services::Base
  # Platform-layer view of every venture (client). Not tenant-scoped — the super
  # admin sees all workspaces, so these methods deliberately query Client
  # directly rather than through `scoped`.
  def model = Client

  def list
    ds = Client.order(Sequel.desc(:created_at))
    ds = ds.where(active: true)  if qs[:status] == 'active'
    ds = ds.where(active: false) if qs[:status] == 'suspended'
    if qs[:search].present?
      term = "%#{qs[:search]}%"
      ds = ds.where { Sequel.ilike(:name, term) | Sequel.ilike(:email, term) }
    end
    clients = ds.all
    ids     = clients.map(&:id)
    # Two aggregate queries for the whole page instead of two per venture (N+1).
    users   = User.where(client_id: ids).group_and_count(:client_id).all.to_h { |r| [r[:client_id], r[:count]] }
    plots   = Plot.where(client_id: ids).group_and_count(:client_id).all.to_h { |r| [r[:client_id], r[:count]] }
    return_success(
      clients.map { |c| venture_pos(c, users[c.id] || 0, plots[c.id] || 0) },
      counts: counts_by_status
    )
  end

  def get
    c = item
    return_success(venture_pos(c, User.where(client_id: c.id).count, Plot.where(client_id: c.id).count))
  end

  # Suspend a venture (active → false). Logins are not force-revoked here; this
  # flags the workspace so access enforcement can build on it later.
  def suspend
    item.active = false
    save(item) { return_success(venture_pos(item)) }
  end

  def activate
    item.active = true
    save(item) { return_success(venture_pos(item)) }
  end

  # Super-admin dashboard widgets. All counts are aggregate queries (no rows
  # loaded into Ruby) so the dashboard returns fast even at scale.
  def overview
    total  = Client.count
    active = Client.where(active: true).count
    return_success(
      total_ventures:   total,
      active:           active,
      suspended:        total - active,
      pending_requests: OnboardingRequest.where(status: 'submitted').count,
      total_users:      User.count,
      total_plots:      Plot.count,
      recent_requests:  OnboardingRequest.order(Sequel.desc(:created_at)).limit(5).all.map(&:as_pos)
    )
  end

  def item(id = rp[:id]) = (@item ||= Client[id] || return_errors!('Venture not found', 404))

  private

  def counts_by_status
    { all: Client.count, active: Client.where(active: true).count,
      suspended: Client.where(active: false).count }
  end

  def venture_pos(c, users = 0, plots = 0)
    { id: c.id, name: c.name, email: c.email, active: c.active,
      status: c.active ? 'active' : 'suspended',
      users: users, plots: plots, created_at: c.created_at }
  end
end
