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

  private

  def hour_label(h)
    suffix = h < 12 ? 'a' : 'p'
    hr = h % 12
    hr = 12 if hr.zero?
    "#{hr}#{suffix}"
  end
end
