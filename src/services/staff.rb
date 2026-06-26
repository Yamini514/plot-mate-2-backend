class App::Services::Staff < App::Services::Base
  def model = App::Models::Staff

  def list
    ds = scoped.order(Sequel.asc(:name))
    ds = ds.where(kind: qs[:kind])     if qs[:kind].present?   && qs[:kind]   != 'all'
    ds = ds.where(status: qs[:status]) if qs[:status].present? && qs[:status] != 'all'
    return_success(ds.all.map(&:as_pos))
  end

  def get = return_success(item.as_pos)

  # Vendors eligible for work-order assignment: active + verified, optionally
  # filtered to those that handle a given service category.
  def eligible
    rows = scoped.where(kind: 'vendor', verified: true, status: 'active').all
    if qs[:category].present?
      cat  = qs[:category].to_s
      rows = rows.select { |s| (s.categories || []).map(&:to_s).include?(cat) }
    end
    return_success(rows.map(&:as_pos))
  end

  # Mark compliance verified (license/insurance checked) — gates eligibility.
  def verify
    item.set(verified: true)
    save(item) do
      App::Audit.record('vendor.verify', entity: item, client_id: current_client_id,
                        summary: "Verified vendor #{item.name}")
      return_success(item.as_pos)
    end
  end

  def toggle_preferred
    item.set(preferred: !item.preferred)
    save(item) { return_success(item.as_pos) }
  end

  # Derived performance metrics for a vendor: work-order volume, completion,
  # on-time %, reopen rate, total billed, and the average rating. All aggregate.
  def performance
    sid = item.id
    tickets = App::Models::Ticket.where(client_id: current_client_id, assignee_staff_id: sid)
    total     = tickets.count
    completed = tickets.where(status: %w[resolved closed]).count
    reopened  = tickets.where { reopen_count > 0 }.count
    done = tickets.where(status: %w[resolved closed]).exclude(resolved_at: nil).all
    on_time = done.count { |t| t.due_at.nil? || t.resolved_at <= t.due_at }
    billed  = tickets.sum { |t| (t.labour_cost_paise || 0) + (t.materials_cost_paise || 0) }
    ratings = App::Models::VendorRating.where(client_id: current_client_id, staff_id: sid).all
    avg = ratings.empty? ? nil : (ratings.sum(&:score).to_f / ratings.size).round(2)
    return_success(
      vendor: item.as_pos,
      total_orders: total, completed: completed, reopened: reopened,
      on_time_pct: done.empty? ? nil : (on_time * 100 / done.size),
      completion_pct: total.zero? ? nil : (completed * 100 / total),
      total_billed: (billed || 0) / 100,
      avg_rating: avg, rating_count: ratings.size,
      recent_ratings: ratings.sort_by { |x| -x.id }.first(5).map(&:as_pos)
    )
  end

  # Record a 1–5 rating for this vendor (optionally tied to a work order).
  def rate
    validate!('score' => App::Validate.number(params[:score], min: 1, max: 5, integer: true, label: 'Score'))
    rating = App::Models::VendorRating.new(
      client_id: current_client_id, staff_id: item.id,
      ticket_id: params[:ticket_id], score: params[:score].to_i,
      note: params[:note], rated_by: App.cu.id
    )
    save(rating) do |rt|
      App::Audit.record('vendor.rate', entity: item, client_id: current_client_id,
                        summary: "Rated #{item.name} #{rt.score}/5")
      return_success(rt.as_pos)
    end
  end

  # Issue a vendor-portal login for this staff/vendor record. Creates a User with
  # role :vendor linked back to the staff row (extras.staff_id), so the vendor
  # only sees the work orders assigned to them. Returns a one-time temp password.
  def create_login
    s = item
    email = s.email.to_s.strip.downcase
    return_errors!('Add an email to this vendor first', 422) if email.empty?
    if App::Models::User.where(client_id: current_client_id, email: email, active: true).first
      return_errors!('A login already exists for this email', 422)
    end
    temp = SecureRandom.alphanumeric(10)
    u = App::Models::User.new(
      client_id: current_client_id, full_name: s.name, email: email,
      phone_number: (s.phone.to_s =~ /\A\d{10}\z/ ? s.phone : nil),
      role: App::Models::User::ROLES[:vendor], active: true,
      extras: { 'title' => "Vendor · #{s.role.presence || 'Service partner'}", 'staff_id' => s.id }
    )
    u.password = temp
    save(u) do
      App::Audit.record('vendor.create_login', entity: s, client_id: current_client_id,
                        summary: "Created vendor login for #{s.name}")
      return_success(email: email, temp_password: temp)
    end
  end

  def create
    obj = model.new(coerced)
    obj.client_id = current_client_id
    obj.code ||= "ST-#{scoped.count + 1}"
    save(obj) { |s| return_success(s.as_pos) }
  end

  def update
    item.set_fields(coerced, coerced.keys)
    save(item) { |s| return_success(s.as_pos) }
  end

  def item(id = rp[:id]) = (@item ||= scoped[id] || return_errors!('Staff not found', 404))

  private

  def coerced
    @coerced ||= begin
      d = data_for(:save)
      d['monthly_salary_paise'] = (d.delete('monthly_salary').to_f * 100).round if d.key?('monthly_salary')
      d['kind'] = d.delete('type') if d.key?('type')
      d
    end
  end

  def self.fields
    { save: %i[name role phone email monthly_salary joined_on status type
               categories license_no license_expiry insurance_policy
               insurance_expiry sla_response_hours rate_card] }
  end
end
