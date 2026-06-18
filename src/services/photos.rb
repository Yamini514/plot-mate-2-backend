class App::Services::Photos < App::Services::Base
  def model = Photo

  def list
    ds = scoped.where(active: true).order(Sequel.desc(:date), Sequel.desc(:id))
    ds = ds.where(category: qs[:category]) if qs[:category].present? && qs[:category] != 'all'
    return_success(ds.all.map(&:as_pos))
  end

  def create
    obj = model.new(data_for(:save))
    obj.client_id = current_client_id
    obj.code ||= "IMG-#{scoped.count + 1}"
    obj.date ||= Date.today
    save(obj) { |p| return_success(p.as_pos) }
  end

  def delete
    item.active = false
    save(item) { return_success(item.as_pos) }
  end

  def item(id = rp[:id]) = (@item ||= scoped[id] || return_errors!('Photo not found', 404))

  def self.fields
    { save: %i[url file_key caption category date] }
  end
end
