class App::Services::VehicleLogs < App::Services::Base
  # Gate vehicle register. Logging a vehicle in stamps entry; `exit` stamps the
  # departure. Tenant-scoped; audited on entry/exit.
  def model = VehicleLog

  VEHICLE_RE = /\A[A-Za-z0-9 -]{4,15}\z/  # lenient plate format

  def list
    ds = scoped.order(Sequel.desc(:created_at))
    ds = ds.where(status: qs[:status]) if qs[:status].present? && qs[:status] != 'all'
    ds = ds.where(vehicle_type: qs[:type]) if qs[:type].present? && qs[:type] != 'all'
    if qs[:search].present?
      term = "%#{qs[:search]}%"
      ds = ds.where { Sequel.ilike(:vehicle_no, term) | Sequel.ilike(:plot_no, term) | Sequel.ilike(:driver_name, term) }
    end
    total = ds.count
    return_success(ds.offset(offset).limit(limit).all.map(&:as_pos),
                   counts: counts, **pagination_meta(total))
  end

  def get = return_success(item.as_pos)

  # Log a vehicle in at the gate.
  def create
    validate!(
      'vehicle_no' => vehicle_no_error(params[:vehicle_no]),
      'phone'      => App::Validate.phone(params[:phone])
    )
    obj = model.new(data_for(:save))
    obj.client_id = current_client_id
    obj.code ||= "VEH-#{1000 + scoped.count + 1}"
    obj.vehicle_no = obj.vehicle_no.to_s.upcase.strip
    obj.status = 'inside'
    obj.entry_at ||= Time.now
    obj.created_by = App.cu.id
    save(obj) do |v|
      App::Audit.record('vehicle.entry', entity: v, client_id: v.client_id,
                        summary: "Vehicle #{v.vehicle_no} entered (#{v.owner_kind}#{v.plot_no ? " · plot #{v.plot_no}" : ''})")
      return_success(v.as_pos)
    end
  end

  def exit
    return_errors!('Vehicle already exited', 422) if item.status == 'exited'
    item.set(status: 'exited', exit_at: Time.now)
    save(item) do |v|
      App::Audit.record('vehicle.exit', entity: v, client_id: v.client_id,
                        summary: "Vehicle #{v.vehicle_no} exited")
      return_success(v.as_pos)
    end
  end

  def item(id = rp[:id]) = (@item ||= scoped[id] || return_errors!('Vehicle log not found', 404))

  private

  def vehicle_no_error(no)
    return 'Vehicle number is required' if no.to_s.strip.empty?
    no.to_s.strip.match?(VEHICLE_RE) ? nil : 'Enter a valid vehicle number'
  end

  def counts
    { all: scoped.count, inside: scoped.where(status: 'inside').count,
      exited: scoped.where(status: 'exited').count }
  end

  def self.fields
    { save: %i[vehicle_no vehicle_type owner_kind plot_no driver_name phone parking_slot] }
  end
end
