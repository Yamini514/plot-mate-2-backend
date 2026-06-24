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

  # Suspend a venture (active → false, status → suspended). Logins are not
  # force-revoked here; this flags the workspace so access enforcement can build
  # on it later. Audited.
  def suspend
    item.set(active: false, status: 'suspended', suspended_at: Time.now,
             suspended_by: App.cu.id, suspension_reason: params[:reason])
    save(item) do
      App::Audit.record('venture.suspend', entity: item, client_id: item.id,
                        summary: "Suspended venture #{item.name}", meta: { reason: params[:reason] })
      return_success(venture_pos(item))
    end
  end

  def activate
    item.set(active: true, status: 'active', suspended_at: nil,
             suspended_by: nil, suspension_reason: nil)
    save(item) do
      App::Audit.record('venture.activate', entity: item, client_id: item.id,
                        summary: "Activated venture #{item.name}")
      return_success(venture_pos(item))
    end
  end

  # Flag a live venture for changes (without suspending access). The reason is
  # surfaced to the Venture Admin and recorded in the trail.
  def request_changes
    item.set(status: 'modifications_requested')
    save(item) do
      App::Audit.record('venture.request_changes', entity: item, client_id: item.id,
                        summary: "Requested changes for #{item.name}", meta: { reason: params[:reason] })
      return_success(venture_pos(item))
    end
  end

  # Soft-archive: out of the active roster but never hard-deleted (retention).
  def archive
    item.set(active: false, status: 'archived')
    save(item) do
      App::Audit.record('venture.archive', entity: item, client_id: item.id,
                        summary: "Archived venture #{item.name}")
      return_success(venture_pos(item))
    end
  end

  # Read-only window into a venture's documents (super admin can view, not edit).
  def documents
    docs = Document.where(client_id: item.id).order(Sequel.desc(:created_at)).all
    return_success(docs.map(&:as_pos))
  end

  # The Venture Admin(s) of this workspace.
  def admins
    admins = User.where(client_id: item.id, role: User::ROLES[:admin]).order(:full_name).all
    return_success(admins.map(&:as_pos))
  end

  # Grant time-boxed, audited support access to a venture's operational data.
  # Records the grant; a real token-mint can build on this entry. Without an
  # active grant, operational endpoints must reject a super admin.
  def grant_support_access
    minutes = [[(params[:minutes] || 30).to_i, 5].max, 240].min
    expires = Time.now + minutes * 60
    App::Audit.record('support.access.grant', entity: item, client_id: item.id,
                      summary: "Support access to #{item.name} for #{minutes}m",
                      meta: { reason: params[:reason], scope: params[:scope] || 'read',
                              expires_at: expires })
    return_success(client_id: item.id, scope: params[:scope] || 'read',
                   expires_at: expires, minutes: minutes)
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
      pending_requests: OnboardingRequest.where(status: %w[submitted changes_requested]).count,
      total_users:      User.count,
      total_plots:      Plot.count,
      open_tickets:     platform_open_tickets,
      recent_requests:  OnboardingRequest.order(Sequel.desc(:created_at)).limit(5).all.map(&:as_pos),
      recent_audits:    AuditLog.order(Sequel.desc(:created_at)).limit(5).all.map(&:as_pos)
    )
  end

  def item(id = rp[:id]) = (@item ||= Client[id] || return_errors!('Venture not found', 404))

  private

  # Defensive: platform_tickets may not exist yet on an un-migrated DB.
  def platform_open_tickets
    return 0 unless App::Models.const_defined?(:PlatformTicket)
    PlatformTicket.where(status: PlatformTicket::OPEN_STATUSES).count
  rescue
    0
  end

  def counts_by_status
    { all: Client.count, active: Client.where(active: true).count,
      suspended: Client.where(active: false).count }
  end

  def venture_pos(c, users = 0, plots = 0)
    { id: c.id, name: c.name, email: c.email, active: c.active,
      status: c.status_label, users: users, plots: plots,
      suspension_reason: c.suspension_reason, created_at: c.created_at }
  end
end
