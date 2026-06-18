class App::Services::Blacklist < App::Services::Base
  def model = BlacklistEntry

  def list
    ds = scoped.order(Sequel.desc(:created_at))
    ds = ds.where(kind: qs[:kind]) if qs[:kind].present? && qs[:kind] != 'all'
    return_success(ds.all.map(&:as_pos))
  end

  def get = return_success(item.as_pos)

  def create
    obj = model.new(data_for(:save))
    obj.client_id = current_client_id
    prefix = obj.kind == 'vehicle' ? 'BL-C' : 'BL-V'
    obj.code ||= "#{prefix}-#{scoped.where(kind: obj.kind).count + 1}"
    obj.added_by ||= App.cu.user_obj.full_name
    obj.status ||= 'blacklisted'
    save(obj) { |b| return_success(b.as_pos) }
  end

  def update
    data = data_for(:save)
    item.set_fields(data, data.keys)
    save(item) { |b| return_success(b.as_pos) }
  end

  def item(id = rp[:id]) = (@item ||= scoped[id] || return_errors!('Entry not found', 404))

  def self.fields
    { save: %i[kind name phone plate model reason added_by attempts status] }
  end
end
