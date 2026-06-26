class App::Services::Ventures < App::Services::Base
  # Platform-layer view of every venture (client). Not tenant-scoped — the super
  # admin sees all workspaces, so these methods deliberately query Client
  # directly rather than through `scoped`.
  def model = Client

  SORTABLE = { 'name' => :name, 'email' => :email, 'status' => :status,
               'created_at' => :created_at }.freeze

  def list
    ds = Client.dataset
    ds = ds.where(active: true)  if qs[:status] == 'active'
    ds = ds.where(active: false) if qs[:status] == 'suspended'
    if qs[:search].present?
      term = "%#{qs[:search]}%"
      ds = ds.where { Sequel.ilike(:name, term) | Sequel.ilike(:email, term) }
    end
    ds      = apply_sort(ds, SORTABLE)
    total   = ds.count
    clients = ds.offset(offset).limit(limit).all
    ids     = clients.map(&:id)
    # Two aggregate queries for the whole page instead of two per venture (N+1).
    users   = User.where(client_id: ids).group_and_count(:client_id).all.to_h { |r| [r[:client_id], r[:count]] }
    plots   = Plot.where(client_id: ids).group_and_count(:client_id).all.to_h { |r| [r[:client_id], r[:count]] }
    return_success(
      clients.map { |c| venture_pos(c, users[c.id] || 0, plots[c.id] || 0) },
      counts: counts_by_status, **pagination_meta(total)
    )
  end

  def get
    return_success(venture_detail(item))
  end

  # Edit the venture's descriptive profile (registration no., type, address …).
  # Stored in clients.settings['profile'] — no dedicated columns — so it's
  # additive and editable without a migration. Audited.
  PROFILE_FIELDS = %w[registration_number venture_type address city state country].freeze

  def update_info
    profile = (item.settings || {})['profile'] || {}
    PROFILE_FIELDS.each { |f| profile[f] = params[f].to_s.strip if params.key?(f) }
    validate!(
      'registration_number' => App::Validate.text(profile['registration_number'], max: 80, required: false),
      'venture_type'        => App::Validate.text(profile['venture_type'], max: 60, required: false),
      'address'             => App::Validate.text(profile['address'], max: 240, required: false),
    )
    item.settings = (item.settings || {}).merge('profile' => profile)
    save(item) do
      App::Audit.record('venture.update_info', entity: item, client_id: item.id,
                        summary: "Updated venture profile for #{item.name}")
      return_success(venture_detail(item))
    end
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
      plot_status:      plot_status_counts,
      ticket_status:    platform_ticket_status,
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

  # Plot-occupancy breakdown for the dashboard donut (lifecycle status across all
  # ventures). Null status (pre-0033 rows) counts as available.
  def plot_status_counts
    Plot.group_and_count(:status).all
        .each_with_object(Hash.new(0)) { |r, h| h[r[:status] || 'available'] += r[:count] }
  rescue
    {}
  end

  def platform_ticket_status
    return {} unless App::Models.const_defined?(:PlatformTicket)
    PlatformTicket.group_and_count(:status).all
                  .each_with_object({}) { |r, h| h[r[:status]] = r[:count] }
  rescue
    {}
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

  # Rich payload for the Venture Details page: identity, descriptive profile
  # (with onboarding provenance) and live statistics. All counts are aggregate
  # queries (no rows loaded), guarded so an un-migrated/empty venture is fine.
  def venture_detail(c)
    cid = c.id
    plot_counts = Plot.where(client_id: cid).group_and_count(:status).all
                      .each_with_object(Hash.new(0)) { |r, h| h[(r[:status] || 'available')] += r[:count] }
    total_plots = plot_counts.values.sum
    role_counts = User.where(client_id: cid).group_and_count(:role).all
                      .each_with_object(Hash.new(0)) { |r, h| h[r[:role]] += r[:count] }
    open_tickets  = venture_tickets(cid, :open)
    total_tickets = venture_tickets(cid, :all)
    profile = (c.settings || {})['profile'] || {}
    req     = c.onboarding_request_id ? OnboardingRequest[c.onboarding_request_id] : nil

    {
      id: cid, name: c.name, email: c.email, active: c.active,
      status: c.status_label, created_at: c.created_at, updated_at: c.updated_at,
      approved_at: c.approved_at, suspended_at: c.suspended_at,
      suspension_reason: c.suspension_reason,
      info: {
        registration_number: profile['registration_number'],
        venture_type: profile['venture_type'],
        address: profile['address'] || req&.location,
        city: profile['city'], state: profile['state'], country: profile['country'],
        location: req&.location, description: req&.description,
        requester_name: req&.requester_name, requester_email: req&.requester_email,
        requester_phone: req&.requester_phone, plot_count: req&.plot_count
      },
      stats: {
        total_plots: total_plots,
        occupied_plots: plot_counts['booked'] + plot_counts['sold'],
        vacant_plots: plot_counts['available'],
        blocked_plots: plot_counts['blocked'],
        total_users: role_counts.values.sum,
        residents: role_counts[User::ROLES[:member]],
        committee: role_counts[User::ROLES[:admin]],
        guards: role_counts[User::ROLES[:guard]],
        staff: venture_staff(cid, 'staff'),
        vendors: venture_staff(cid, 'vendor'),
        open_tickets: open_tickets,
        closed_tickets: total_tickets - open_tickets
      }
    }
  end

  # Defensive aggregate helpers — a fresh/un-migrated venture may have no rows or
  # the table may be absent on an old DB; never let the detail page 500.
  def venture_tickets(cid, scope)
    return 0 unless App::Models.const_defined?(:Ticket)
    ds = Ticket.where(client_id: cid)
    ds = ds.where(status: Ticket::OPEN_STATUSES) if scope == :open
    ds.count
  rescue
    0
  end

  def venture_staff(cid, kind)
    return 0 unless App::Models.const_defined?(:Staff)
    Staff.where(client_id: cid, kind: kind).count
  rescue
    0
  end
end
