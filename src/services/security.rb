class App::Services::Security < App::Services::Base
  SEV_COLORS = { 'low' => '#94a3b8', 'medium' => '#f59e0b', 'high' => '#f97316', 'critical' => '#ef4444' }.freeze
  OPEN_STATUSES = %w[open investigating escalated].freeze

  # Community-wide security snapshot for the admin dashboard. Everything here is
  # derived from real records (visitors, deliveries, incidents, guard accounts,
  # blacklist) — no fabricated KPIs. One round-trip powers the whole page.
  def overview
    cid   = current_client_id
    today = Date.today

    visitors   = Visitor.where(client_id: cid).all
    deliveries = Delivery.where(client_id: cid).all
    incidents  = Incident.where(client_id: cid).all
    guards     = User.where(client_id: cid, role: User::ROLES[:guard], active: true).order(:full_name).all
    blacklist  = BlacklistEntry.where(client_id: cid).all

    open_inc = incidents.select { |i| OPEN_STATUSES.include?(i.status) }
    on_day   = ->(t, d) { t&.to_date == d }
    vis_time = ->(v) { v.check_in || v.created_at }
    del_time = ->(x) { x.received_at || x.created_at }
    inc_time = ->(i) { i.occurred_at || i.created_at }

    traffic_trend = (0..6).map do |i|
      d = today - (6 - i)
      { day: d.strftime('%a'),
        visitors:   visitors.count   { |v| on_day.(vis_time.(v), d) },
        deliveries: deliveries.count { |x| on_day.(del_time.(x), d) } }
    end

    incident_severity = Incident::SEVERITIES.map do |s|
      { name: s.capitalize, value: incidents.count { |i| i.severity == s }, color: SEV_COLORS[s] }
    end

    # "Alerts" are the open high/critical incidents — derived, never invented.
    alerts = open_inc
             .select { |i| %w[high critical].include?(i.severity) }
             .sort_by { |i| inc_time.(i) || Time.at(0) }.reverse.first(5)
             .map do |i|
               { id: i.id, title: i.incident_type, body: i.location,
                 level: i.severity == 'critical' ? 'high' : 'medium',
                 status: i.status, time: inc_time.(i) }
             end

    recent = incidents.sort_by { |i| inc_time.(i) || Time.at(0) }.reverse.first(6).map(&:as_pos)

    return_success(
      visitors_today:     visitors.count { |v| on_day.(vis_time.(v), today) },
      deliveries_today:   deliveries.count { |x| on_day.(del_time.(x), today) },
      packages_waiting:   deliveries.count { |d| %w[waiting received].include?(d.status) },
      pending_approvals:  visitors.count { |v| v.status == 'pending' },
      visitors_inside:    visitors.count { |v| v.check_in && !v.check_out },
      total_incidents:    incidents.length,
      open_incidents:     open_inc.length,
      critical_incidents: incidents.count { |i| %w[high critical].include?(i.severity) },
      guards_total:       guards.length,
      blacklist_visitors: blacklist.count { |b| b.kind == 'visitor' },
      blacklist_vehicles: blacklist.count { |b| b.kind == 'vehicle' },
      traffic_trend:      traffic_trend,
      incident_severity:  incident_severity,
      team:               guards.map { |g| { name: g.full_name, title: g.extras&.dig('title') || 'Security Guard', status: 'active' } },
      recent_incidents:   recent,
      alerts:             alerts
    )
  end

  # Guard attendance: most recent shift sessions (login → logout timings) with
  # the guard's name/id attached. Active sessions (no ended_at) are "on duty".
  def guard_sessions
    # Dormant until the shift_sessions migration runs — return an empty log
    # rather than 500 so the admin page still renders cleanly.
    return return_success([]) unless App::Models.const_defined?(:ShiftSession)

    cid    = current_client_id
    guards = User.where(client_id: cid, role: User::ROLES[:guard]).all
                 .each_with_object({}) { |g, h| h[g.id] = g }

    sessions = ShiftSession.where(client_id: cid)
                           .order(Sequel.desc(:started_at)).limit(60).all

    return_success(sessions.map do |s|
      g = guards[s.user_id]
      s.as_pos.merge(
        guard_name: g&.full_name || 'Former guard',
        guard_id:   g&.extras&.dig('guard_id'),
        title:      g&.extras&.dig('title') || 'Security Guard'
      )
    end)
  end
end
