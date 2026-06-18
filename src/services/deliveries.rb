class App::Services::Deliveries < App::Services::Base
  def model = Delivery

  def list
    ds = scoped.order(Sequel.desc(:created_at))
    ds = ds.where(status: qs[:status]) if qs[:status].present? && qs[:status] != 'all'
    return_success(ds.all.map(&:as_pos))
  end

  def get = return_success(item.as_pos)

  def create
    obj = model.new(data_for(:save))
    obj.client_id = current_client_id
    obj.code ||= "PKG-#{7740 + scoped.count + 1}"
    obj.received_at ||= Time.now
    obj.status ||= 'waiting'
    save(obj) { |d| return_success(d.as_pos) }
  end

  # Hand the package to the resident.
  def handover
    item.handover!
    return_success(item.as_pos)
  end

  def item(id = rp[:id]) = (@item ||= scoped[id] || return_errors!('Delivery not found', 404))

  def self.fields
    { save: %i[courier agent resident_name plot_no status] }
  end
end
