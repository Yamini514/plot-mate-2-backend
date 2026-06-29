class App::Services::Roles < App::Services::Base
  # Custom committee roles + their permission lists, per venture. CRUD only;
  # the approval matrix (clients.settings['approval_matrix']) references these by
  # name. Tenant-scoped.
  def model = App::Models::Role

  def list
    # First view of a venture with no roles seeds the default templates so admins
    # start with President/Treasurer/Secretary/… they can edit or clone.
    App::Models::Role.seed_templates!(current_client_id) if scoped.count.zero?
    rows = scoped.order(Sequel.asc(:name)).all
    counts = App::Models::User.where(client_id: current_client_id).exclude(role_id: nil)
                              .group_and_count(:role_id).all.to_h { |r| [r[:role_id], r[:count]] }
    return_success(rows.map { |r| r.as_pos.merge(user_count: counts[r.id] || 0) },
                   catalogue: App::Models::Role::PERMISSIONS,
                   modules: App::Models::Role::MODULES)
  end

  def get = return_success(item.as_pos)

  def create
    r = model.new(coerced)
    r.client_id = current_client_id
    save(r) do |row|
      App::Audit.record('role.create', entity: row, client_id: current_client_id, summary: "Created role #{row.name}")
      return_success(row.as_pos)
    end
  end

  def update
    item.set_fields(coerced, coerced.keys)
    save(item) do |row|
      App::Audit.record('role.update', entity: row, client_id: current_client_id,
                        summary: "Updated role #{row.name}", meta: { permissions: row.effective_permissions })
      return_success(row.as_pos)
    end
  end

  def delete
    return_errors!('Reassign its members before deleting this role', 422) if role_user_count(item.id).positive?
    name = item.name
    item.destroy
    App::Audit.record('role.delete', entity_type: 'Role', client_id: current_client_id, summary: "Deleted role #{name}")
    return_success(id: item.id)
  end

  # Duplicate a role (name + permissions) so admins can fork a template.
  def clone
    src = item
    r = model.new(client_id: current_client_id, name: "#{src.name} (copy)",
                  description: src.description, permissions: src.permissions || [], active: true)
    save(r) do |row|
      App::Audit.record('role.create', entity: row, client_id: current_client_id, summary: "Cloned role #{src.name}")
      return_success(row.as_pos)
    end
  end

  def toggle_active
    item.set(active: !(item.active.nil? ? true : item.active))
    save(item) { |row| return_success(row.as_pos) }
  end

  # Members assigned to this role (drives the "View users" action).
  def users
    rows = App::Models::User.where(client_id: current_client_id, role_id: item.id).all
    return_success(rows.map { |u| { id: u.id, full_name: u.full_name, email: u.email, active: u.active } })
  end

  def item(id = rp[:id]) = (@item ||= scoped[id] || return_errors!('Role not found', 404))

  private

  def role_user_count(rid)
    App::Models::User.where(client_id: current_client_id, role_id: rid).count
  end

  # Keep only known permission keys so the list can't be polluted.
  def coerced
    @coerced ||= begin
      d = data_for(:save)
      if d.key?('permissions') && d['permissions'].is_a?(Array)
        d['permissions'] = d['permissions'].map(&:to_s) & App::Models::Role::PERMISSIONS
      end
      d
    end
  end

  def self.fields
    { save: %i[name description permissions active] }
  end
end
