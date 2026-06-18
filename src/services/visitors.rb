class App::Services::Visitors < App::Services::Base
  def model = Visitor

  def list
    ds = scoped.order(Sequel.desc(:created_at))
    ds = ds.where(status: qs[:status]) if qs[:status].present? && qs[:status] != 'all'
    if qs[:search].present?
      term = "%#{qs[:search]}%"
      ds = ds.where { Sequel.ilike(:name, term) | Sequel.ilike(:plot_no, term) | Sequel.ilike(:resident_name, term) }
    end
    return_success(ds.all.map(&:as_pos))
  end

  def get = return_success(item.as_pos)

  def create
    obj = model.new(data_for(:save))
    obj.client_id = current_client_id
    obj.code ||= "VIS-#{2400 + scoped.count + 1}"
    obj.status ||= 'pending'
    save(obj) { |v| return_success(v.as_pos) }
  end

  def update
    data = data_for(:save)
    item.set_fields(data, data.keys)
    save(item) { |v| return_success(v.as_pos) }
  end

  # Guard action: approve | reject | checkin | checkout
  def action
    return_errors!('Invalid action', 400) unless item.apply_action!(params[:action].to_s)
    return_success(item.as_pos)
  end

  def item(id = rp[:id]) = (@item ||= scoped[id] || return_errors!('Visitor not found', 404))

  def self.fields
    { save: %i[name phone resident_name plot_no purpose vehicle_no status] }
  end
end
