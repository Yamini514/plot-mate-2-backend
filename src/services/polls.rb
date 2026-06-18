class App::Services::Polls < App::Services::Base
  def model = Poll

  def list
    ds = scoped.order(Sequel.desc(:created_at))
    ds = ds.where(status: qs[:status]) if qs[:status].present? && qs[:status] != 'all'
    uid = App.cu.id
    return_success(ds.all.map { |p| p.as_pos(uid) })
  end

  def get = return_success(item.as_pos(App.cu.id))

  def create
    obj = model.new(data_for(:save))
    obj.client_id = current_client_id
    obj.code ||= "PL-#{scoped.count + 1}"
    obj.status ||= 'active'
    save(obj) { |p| return_success(p.as_pos) }
  end

  def update
    data = data_for(:save)
    item.set_fields(data, data.keys)
    save(item) { |p| return_success(p.as_pos) }
  end

  def vote
    if item.record_vote!(App.cu.id, params[:option_id])
      return_success(item.as_pos(App.cu.id))
    else
      return_errors!('Already voted or poll closed', 422)
    end
  end

  def close
    item.status = 'closed'
    save(item) { |p| return_success(p.as_pos) }
  end

  # Deleting a poll also clears its cast votes so no orphaned rows remain.
  def delete
    App.db.transaction do
      App.db[:poll_votes].where(poll_id: item.id).delete
      res = item.delete
      res ? return_success(item.as_pos) : return_errors!('Unable to delete')
    end
  rescue => e
    App.logger.error(e.message)
    return_errors!(e.message, 400)
  end

  def item(id = rp[:id]) = (@item ||= scoped[id] || return_errors!('Poll not found', 404))

  def self.fields
    { save: %i[question description options status closes_at] }
  end
end
