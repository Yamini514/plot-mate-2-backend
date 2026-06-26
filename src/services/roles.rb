class App::Services::Roles < App::Services::Base
  # Custom committee roles + their permission lists, per venture. CRUD only;
  # the approval matrix (clients.settings['approval_matrix']) references these by
  # name. Tenant-scoped.
  def model = App::Models::Role

  def list
    return_success(scoped.order(Sequel.asc(:name)).all.map(&:as_pos),
                   catalogue: App::Models::Role::PERMISSIONS)
  end

  def get = return_success(item.as_pos)

  def create
    r = model.new(coerced)
    r.client_id = current_client_id
    save(r) { |row| return_success(row.as_pos) }
  end

  def update
    item.set_fields(coerced, coerced.keys)
    save(item) { |row| return_success(row.as_pos) }
  end

  def delete
    item.destroy
    return_success(id: item.id)
  end

  def item(id = rp[:id]) = (@item ||= scoped[id] || return_errors!('Role not found', 404))

  private

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
