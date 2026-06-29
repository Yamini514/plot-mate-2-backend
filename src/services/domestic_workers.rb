class App::Services::DomesticWorkers < App::Services::Base
  # Domestic-worker register + gate attendance (entry/exit). Tenant-scoped; the
  # entry/exit actions are audited.
  def model = DomesticWorker

  def list
    ds = scoped.order(Sequel.asc(:name))
    ds = ds.where(active: true)  if qs[:status] == 'active'
    ds = ds.where(active: false) if qs[:status] == 'inactive'
    ds = ds.where(worker_type: qs[:type]) if qs[:type].present? && qs[:type] != 'all'
    if qs[:search].present?
      term = "%#{qs[:search]}%"
      ds = ds.where { Sequel.ilike(:name, term) | Sequel.ilike(:plot_no, term) }
    end
    return_success(ds.all.map(&:as_pos))
  end

  def get
    return_success(item.as_pos.merge(history: item.attendance.limit(50).map(&:as_pos)))
  end

  def create
    validate!(
      'name'  => App::Validate.text(params[:name], min: 2, max: 120, label: 'Name'),
      'phone' => App::Validate.phone(params[:phone])
    )
    obj = model.new(data_for(:save))
    obj.client_id = current_client_id
    obj.code ||= "DW-#{1000 + scoped.count + 1}"
    obj.active = true if obj.active.nil?
    obj.created_by = App.cu.id
    save(obj) { |w| return_success(w.as_pos) }
  end

  def update
    item.set_fields(data_for(:save), data_for(:save).keys)
    save(item) { |w| return_success(w.as_pos) }
  end

  # Gate entry: refuse if inactive or already inside; else open an attendance row.
  def entry
    return_errors!('This worker is marked inactive', 422) unless item.active.nil? || item.active
    return_errors!('Already inside', 422) if item.open_attendance
    App::Models::DomesticAttendance.create(client_id: current_client_id, worker_id: item.id,
                                           entry_at: Time.now, created_by: App.cu.id)
    App::Audit.record('domestic.entry', entity: item, client_id: current_client_id,
                      summary: "#{item.name} (#{item.worker_type}) entered for plot #{item.plot_no}")
    return_success(item.as_pos)
  end

  def exit
    att = item.open_attendance || return_errors!('Not currently inside', 422)
    att.update(exit_at: Time.now)
    App::Audit.record('domestic.exit', entity: item, client_id: current_client_id,
                      summary: "#{item.name} exited")
    return_success(item.as_pos)
  end

  def item(id = rp[:id]) = (@item ||= scoped[id] || return_errors!('Worker not found', 404))

  def self.fields
    { save: %i[name worker_type phone plot_no photo_url active] }
  end
end
