class App::Services::VentureAdmins < App::Services::Base
  # Platform view of Venture Admins (role 2) across every venture. Not
  # tenant-scoped — queries User directly.
  def model = User

  SORTABLE = { 'name' => :full_name, 'email' => :email, 'created_at' => :created_at }.freeze

  def list
    ds = User.where(role: User::ROLES[:admin])
    if qs[:search].present?
      term = "%#{qs[:search]}%"
      ds = ds.where { Sequel.ilike(:full_name, term) | Sequel.ilike(:email, term) }
    end
    ds = ds.where(active: true)  if qs[:status] == 'active'
    ds = ds.where(active: false) if qs[:status] == 'inactive'
    ds     = apply_sort(ds, SORTABLE)
    total  = ds.count
    admins = ds.offset(offset).limit(limit).all
    names  = client_names(admins.map(&:client_id))
    return_success(admins.map { |u| admin_pos(u, names) }, counts: counts, **pagination_meta(total))
  end

  def get = return_success(admin_pos(item, client_names([item.client_id])))

  def activate
    toggle(true, 'venture_admin.activate', 'Activated')
  end

  def deactivate
    toggle(false, 'venture_admin.deactivate', 'Deactivated')
  end

  # Issue a one-time temp password; the admin resets it via the normal flow.
  def reset_password
    temp = SecureRandom.alphanumeric(10)
    item.password = temp
    save(item) do
      App::Audit.record('venture_admin.reset_password', entity: item, client_id: item.client_id,
                        summary: "Reset password for #{item.full_name}")
      return_success(admin_pos(item, client_names([item.client_id])).merge(temp_password: temp))
    end
  end

  def item(id = rp[:id])
    @item ||= (User.where(role: User::ROLES[:admin])[id] || return_errors!('Venture admin not found', 404))
  end

  private

  def toggle(active, action, verb)
    item.set(active: active)
    save(item) do
      App::Audit.record(action, entity: item, client_id: item.client_id,
                        summary: "#{verb} venture admin #{item.full_name}")
      return_success(admin_pos(item, client_names([item.client_id])))
    end
  end

  def counts
    { all: User.where(role: User::ROLES[:admin]).count,
      active: User.where(role: User::ROLES[:admin], active: true).count,
      inactive: User.where(role: User::ROLES[:admin], active: false).count }
  end

  def client_names(ids)
    Client.where(id: ids.compact.uniq).select_hash(:id, :name)
  end

  def admin_pos(u, names)
    u.as_pos.merge(client_id: u.client_id, venture: names[u.client_id])
  end
end
