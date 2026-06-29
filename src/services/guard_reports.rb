class App::Services::GuardReports < App::Services::Base
  SEV_COLORS = { 'low' => '#94a3b8', 'medium' => '#f59e0b', 'high' => '#f97316', 'critical' => '#ef4444' }.freeze

  # Gate analytics derived from real visitor / delivery / incident timestamps.
  def summary
    cid = current_client_id
    visitors   = Visitor.where(client_id: cid).all
    deliveries = Delivery.where(client_id: cid).all
    incidents  = Incident.where(client_id: cid).all

    by_hour = Hash.new(0)
    visitors.each do |v|
      t = v.check_in || v.created_at
      by_hour[t.hour] += 1 if t
    end
    visitors_by_hour = (6..21).map { |h| { hour: hour_label(h), visitors: by_hour[h] } }

    today = Date.today
    traffic_trend = (0..6).map do |i|
      d = today - (6 - i)
      {
        day: d.strftime('%a'),
        visitors: visitors.count { |v| (v.check_in || v.created_at)&.to_date == d },
        deliveries: deliveries.count { |x| (x.received_at || x.created_at)&.to_date == d }
      }
    end

    incident_severity = %w[low medium high critical].map do |s|
      { name: s.capitalize, value: incidents.count { |i| i.severity == s }, color: SEV_COLORS[s] }
    end

    return_success(
      visitors_by_hour: visitors_by_hour,
      traffic_trend: traffic_trend,
      incident_severity: incident_severity,
      totals: {
        visitors: visitors.length, deliveries: deliveries.length,
        incidents: incidents.length,
        packages_waiting: deliveries.count { |d| %w[waiting received].include?(d.status) }
      }
    )
  end

  # Resident roster + recent gate activity (derived from visitor entries/exits).
  def residents
    cid = current_client_id
    plots = Plot.where(client_id: cid, active: true).exclude(owner_name: nil).order(:plot_no).all
    activity = Visitor.where(client_id: cid).order(Sequel.desc(:created_at)).limit(20).all.map do |v|
      {
        id: v.id, type: v.status == 'checked_out' ? 'exit' : 'guest',
        name: v.name, flat: v.plot_no, resident: v.resident_name,
        time: v.check_in || v.created_at, method: v.pass_code ? 'QR pass' : 'Manual'
      }
    end
    return_success(
      residents: plots.map { |p| { plot_no: p.plot_no, name: p.owner_name, phone: p.phone, phase: p.phase } },
      activity: activity
    )
  end

  # The security team covering the gate (real guard accounts), with the
  # signed-in guard flagged. Shift times aren't modelled, so we don't invent them.
  def shift_roster
    cid = current_client_id
    me  = App.cu.id
    guards = User.where(client_id: cid, role: User::ROLES[:guard], active: true).order(:full_name).all
    return_success(guards.map do |g|
      { name: g.full_name,
        guard_id: g.extras&.dig('guard_id'),
        title: g.extras&.dig('title') || 'Security Guard',
        current: g.id == me }
    end)
  end

  # The signed-in guard's own recent gate activity, newest first.
  def recent_actions
    cid = current_client_id
    me  = App.cu.id
    items = []
    Visitor.where(client_id: cid, created_by: me).order(Sequel.desc(:created_at)).limit(10).each do |v|
      items << { id: "v#{v.id}", icon: 'user-plus',
                 text: "Registered visitor #{v.name}#{v.plot_no ? " · #{v.plot_no}" : ''}", at: v.created_at }
    end
    Delivery.where(client_id: cid, created_by: me).order(Sequel.desc(:created_at)).limit(10).each do |d|
      items << { id: "d#{d.id}", icon: 'package',
                 text: "Logged delivery#{d.courier ? " from #{d.courier}" : ''}", at: d.created_at }
    end
    Incident.where(client_id: cid, created_by: me).order(Sequel.desc(:created_at)).limit(10).each do |i|
      items << { id: "i#{i.id}", icon: 'shield-alert',
                 text: "Reported incident: #{i.incident_type}", at: i.created_at }
    end
    recent = items.sort_by { |x| x[:at] || Time.at(0) }.reverse.first(10)
    return_success(recent.map { |x| { id: x[:id], icon: x[:icon], text: x[:text], time: x[:at]&.strftime('%d %b · %I:%M %p') } })
  end

  # Look up a plot by number within the tenant so the gate can verify a visitor's
  # destination against the registry before registering them. Always returns a
  # success envelope (found: true/false) — an unknown plot is a normal result at
  # the gate, never an error to surface to the guard.
  def verify_plot
    cid     = current_client_id
    plot_no = qs[:plot_no].to_s.strip
    return return_success(found: false) if plot_no.empty?

    plot = Plot.where(client_id: cid, active: true)
               .where { Sequel.ilike(:plot_no, plot_no) }.first
    return return_success(found: false, plot_no: plot_no) unless plot

    return_success(
      found:      true,
      plot_no:    plot.plot_no,
      owner_name: plot.owner_name,
      phone:      plot.phone,
      phase:      plot.phase,
      registered: plot.owner_name.present?
    )
  rescue => e
    App.logger.error("verify_plot error: #{e.message}")
    return_success(found: false)
  end

  # Vendor gate verification: verified vendors + their open work-order count, so
  # the guard can confirm a vendor is assigned active work before allowing entry.
  def vendors
    cid = current_client_id
    rows = App::Models::Staff.where(client_id: cid, kind: 'vendor', verified: true).all
    return return_success([]) if rows.empty?
    open_counts = App::Models::Ticket
                  .where(client_id: cid, assignee_staff_id: rows.map(&:id))
                  .where(status: App::Models::Ticket::OPEN_STATUSES)
                  .group_and_count(:assignee_staff_id).all
                  .to_h { |r| [r[:assignee_staff_id], r[:count]] }
    q = qs[:search].to_s.strip.downcase
    rows = rows.select { |s| s.name.to_s.downcase.include?(q) || s.phone.to_s.include?(q) } unless q.empty?
    return_success(rows.map do |s|
      { id: s.id, name: s.name, phone: s.phone, categories: (s.categories || []),
        license_expiry: s.license_expiry, insurance_expiry: s.insurance_expiry,
        open_orders: open_counts[s.id] || 0,
        compliant: !expired?(s.license_expiry) && !expired?(s.insurance_expiry) }
    end)
  rescue => e
    App.logger.error("guard vendors error: #{e.message}")
    return_success([])
  end

  # Unified, searchable gate register across visitors, deliveries, vehicles and
  # domestic staff — one chronological feed the guard/admin can filter + search.
  def gate_register
    cid = current_client_id
    q   = qs[:search].to_s.strip.downcase
    kind = qs[:kind].to_s
    rows = []

    if kind.empty? || kind == 'visitor'
      Visitor.where(client_id: cid).order(Sequel.desc(:created_at)).limit(200).each do |v|
        rows << reg_row('visitor', v.code, v.name, "Plot #{v.plot_no}", v.status, v.check_in || v.created_at, v.check_out)
      end
    end
    if kind.empty? || kind == 'delivery'
      Delivery.where(client_id: cid).order(Sequel.desc(:created_at)).limit(200).each do |d|
        rows << reg_row('delivery', d.code, d.courier, "Plot #{d.plot_no}", d.status, d.received_at || d.created_at, d.delivered_at)
      end
    end
    if (kind.empty? || kind == 'vehicle') && App::Models.const_defined?(:VehicleLog)
      VehicleLog.where(client_id: cid).order(Sequel.desc(:created_at)).limit(200).each do |v|
        rows << reg_row('vehicle', v.code, v.vehicle_no, v.plot_no.to_s.empty? ? v.owner_kind : "Plot #{v.plot_no}", v.status, v.entry_at, v.exit_at)
      end
    end
    if (kind.empty? || kind == 'domestic') && App::Models.const_defined?(:DomesticAttendance)
      App::Models::DomesticAttendance.where(client_id: cid).order(Sequel.desc(:created_at)).limit(200).each do |a|
        w = App::Models::DomesticWorker[a.worker_id]
        rows << reg_row('domestic', "ATT-#{a.id}", w&.name, w ? "#{w.worker_type} · Plot #{w.plot_no}" : nil, a.exit_at ? 'exited' : 'inside', a.entry_at, a.exit_at)
      end
    end

    rows = rows.select { |r| "#{r[:name]} #{r[:detail]} #{r[:code]}".downcase.include?(q) } unless q.empty?
    rows = rows.select { |r| r[:status] == 'rejected' } if qs[:rejected] == 'true'
    rows.sort_by! { |r| r[:at].to_s }
    rows.reverse!
    return_success(rows.first(300))
  rescue => e
    App.logger.error("gate_register error: #{e.message}")
    return_success([])
  end

  private

  def reg_row(kind, code, name, detail, status, at, exit_at)
    { kind: kind, code: code, name: name, detail: detail, status: status, at: at, exit_at: exit_at }
  end

  def expired?(date)
    date && date < Date.today
  rescue StandardError
    false
  end

  def hour_label(h)
    suffix = h < 12 ? 'a' : 'p'
    hr = h % 12
    hr = 12 if hr.zero?
    "#{hr}#{suffix}"
  end
end
