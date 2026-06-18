class App::Services::Announcements < App::Services::Base
  def model = Announcement

  def list
    ds = scoped.order(Sequel.desc(:pinned), Sequel.desc(:date), Sequel.desc(:id))
    ds = ds.where(type: qs[:type]) if qs[:type].present? && qs[:type] != 'all'
    return_success(ds.all.map(&:as_pos))
  end

  def get = return_success(item.as_pos)

  def create
    obj = model.new(data_for(:save))
    obj.client_id = current_client_id
    obj.code ||= "AN-#{scoped.count + 1}"
    obj.author ||= App.cu.user_obj.full_name
    obj.date ||= Date.today
    save(obj) { |a| return_success(a.as_pos) }
  end

  def update
    data = data_for(:save)
    item.set_fields(data, data.keys)
    save(item) { |a| return_success(a.as_pos) }
  end

  def pin
    item.pinned = !item.pinned
    save(item) { |a| return_success(a.as_pos) }
  end

  def item(id = rp[:id]) = (@item ||= scoped[id] || return_errors!('Announcement not found', 404))

  def self.fields
    { save: %i[title body type pinned author date] }
  end
end
