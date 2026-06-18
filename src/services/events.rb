class App::Services::Events < App::Services::Base
  def model = Event

  def list
    ds = scoped.order(Sequel.asc(:date), Sequel.desc(:id))
    uid = App.cu.id
    return_success(ds.all.map { |e| e.as_pos(uid) })
  end

  def get = return_success(item.as_pos(App.cu.id))

  def create
    obj = model.new(data_for(:save))
    obj.client_id = current_client_id
    obj.code ||= "EV-#{scoped.count + 1}"
    save(obj) { |e| return_success(e.as_pos) }
  end

  def update
    data = data_for(:save)
    item.set_fields(data, data.keys)
    save(item) { |e| return_success(e.as_pos) }
  end

  def rsvp
    state = item.toggle_rsvp!(App.cu.id)
    return_success(item.as_pos(App.cu.id).merge(rsvp: state))
  end

  # Deleting an event also clears its RSVPs so no orphaned rows remain.
  def delete
    App.db.transaction do
      App.db[:event_rsvps].where(event_id: item.id).delete
      res = item.delete
      res ? return_success(item.as_pos) : return_errors!('Unable to delete')
    end
  rescue => e
    App.logger.error(e.message)
    return_errors!(e.message, 400)
  end

  def item(id = rp[:id]) = (@item ||= scoped[id] || return_errors!('Event not found', 404))

  def self.fields
    { save: %i[title description date time location type] }
  end
end
