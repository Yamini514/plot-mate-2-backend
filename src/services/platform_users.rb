class App::Services::PlatformUsers < App::Services::Base
  # Every user across every venture (super-admin user management). Not
  # tenant-scoped. The super admin itself (role 3, no client) is excluded from
  # the venture-user roster by default.
  def model = User

  SORTABLE = { 'name' => :full_name, 'email' => :email, 'role' => :role,
               'created_at' => :created_at }.freeze

  def list
    ds = User.exclude(role: User::ROLES[:super_admin])
    if qs[:search].present?
      term = "%#{qs[:search]}%"
      ds = ds.where { Sequel.ilike(:full_name, term) | Sequel.ilike(:email, term) }
    end
    ds = ds.where(role: qs[:role].to_i)   if qs[:role].present?
    ds = ds.where(client_id: qs[:client_id].to_i) if qs[:client_id].present?
    ds = ds.where(active: true)  if qs[:status] == 'active'
    ds = ds.where(active: false) if qs[:status] == 'blocked'

    ds    = apply_sort(ds, SORTABLE)
    total = ds.count
    rows  = ds.offset(offset).limit(limit).all
    names = client_names(rows.map(&:client_id))
    return_success(rows.map { |u| user_pos(u, names) }, counts: counts, **pagination_meta(total))
  end

  def get = return_success(user_pos(item, client_names([item.client_id])))

  # Block = deactivate + record why/when (login is gated on active).
  def block
    item.set(active: false, blocked_at: Time.now, blocked_by: App.cu.id,
             block_reason: params[:reason], current_session_id: nil)
    save(item) do
      App::Audit.record('user.block', entity: item, client_id: item.client_id,
                        summary: "Blocked #{item.full_name} (#{item.email})", meta: { reason: params[:reason] })
      return_success(user_pos(item, client_names([item.client_id])))
    end
  end

  def unblock
    item.set(active: true, blocked_at: nil, blocked_by: nil, block_reason: nil)
    save(item) do
      App::Audit.record('user.unblock', entity: item, client_id: item.client_id,
                        summary: "Unblocked #{item.full_name} (#{item.email})")
      return_success(user_pos(item, client_names([item.client_id])))
    end
  end

  def reset_password
    temp = SecureRandom.alphanumeric(10)
    item.password = temp
    save(item) do
      App::Audit.record('user.reset_password', entity: item, client_id: item.client_id,
                        summary: "Reset password for #{item.full_name}")
      return_success(user_pos(item, client_names([item.client_id])).merge(temp_password: temp))
    end
  end

  # Never resolve to a super admin via this service.
  def item(id = rp[:id])
    @item ||= (User.exclude(role: User::ROLES[:super_admin])[id] || return_errors!('User not found', 404))
  end

  private

  def counts
    base = User.exclude(role: User::ROLES[:super_admin])
    { all: base.count, active: base.where(active: true).count,
      blocked: base.where(active: false).count }
  end

  def client_names(ids)
    Client.where(id: ids.compact.uniq).select_hash(:id, :name)
  end

  def user_pos(u, names)
    u.as_pos.merge(client_id: u.client_id, venture: names[u.client_id],
                   blocked_at: u.blocked_at, block_reason: u.block_reason)
  end
end
