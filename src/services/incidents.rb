class App::Services::Incidents < App::Services::Base
  def model = Incident

  def list
    ds = scoped.order(Sequel.desc(:created_at))
    ds = ds.where(status: qs[:status])     if qs[:status].present?   && qs[:status]   != 'all'
    ds = ds.where(severity: qs[:severity]) if qs[:severity].present? && qs[:severity] != 'all'
    return_success(ds.all.map(&:as_pos))
  end

  def get = return_success(item.as_pos)

  def create
    obj = model.new(column_safe(data_for(:save)))
    obj.client_id = current_client_id
    obj.code ||= "INC-#{3085 + scoped.count + 1}"
    obj.reported_by ||= App.cu.user_obj.full_name
    obj.occurred_at ||= Time.now
    obj.status ||= 'open'
    save(obj) do |i|
      App::Audit.record('incident.created', entity: i, client_id: i.client_id,
                        summary: "Incident #{i.code}: #{i.incident_type} (#{i.severity})")
      notify_admins(i)
      return_success(i.as_pos)
    end
  end

  def update
    data = column_safe(data_for(:save))
    item.set_fields(data, data.keys)
    save(item) { |i| return_success(i.as_pos) }
  end

  def set_status
    return_errors!('Invalid status', 400) unless Incident::STATUSES.include?(params[:status].to_s)
    item.status = params[:status]
    save(item) do |i|
      App::Audit.record('incident.updated', entity: i, client_id: i.client_id,
                        summary: "Incident #{i.code} → #{i.status}")
      return_success(i.as_pos)
    end
  end

  def item(id = rp[:id]) = (@item ||= scoped[id] || return_errors!('Incident not found', 404))

  # Notify every venture admin/committee of a new incident (high-severity ones
  # are the gate's escalation path to management).
  def notify_admins(i)
    App::Models::User.where(client_id: current_client_id, role: App::Models::User::ROLES[:admin], active: true)
                     .select_map(:id).each do |uid|
      App::Notify.create(user_id: uid, client_id: current_client_id, kind: 'incident',
                         title: "New #{i.severity} incident reported",
                         body: "#{i.incident_type} at #{i.location}", link: '/admin/security', entity: i)
    end
  rescue => e
    App.logger.error("incident notify: #{e.message}")
  end

  # Drop any attribute the table doesn't have yet (e.g. `description` before the
  # 0035 migration runs) so a save never raises on an unknown column.
  def column_safe(data)
    cols = model.columns
    data.select { |k, _| cols.include?(k.to_sym) }
  end

  def self.fields
    { save: %i[incident_type location severity reported_by status description] }
  end
end
