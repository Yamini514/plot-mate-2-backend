class App::Services::Reminders < App::Services::Base
  def model = Reminder

  def list
    ds = scoped.order(Sequel.desc(:scheduled_for), Sequel.desc(:id))
    ds = ds.where(status: qs[:status]) if qs[:status].present? && qs[:status] != 'all'
    return_success(ds.all.map(&:as_pos))
  end

  def create
    d = data_for(:save)
    d['amount_paise'] = (d.delete('amount').to_f * 100).round if d.key?('amount')
    obj = model.new(d)
    obj.client_id = current_client_id
    obj.code ||= "RM-#{scoped.count + 1}"
    obj.status ||= 'scheduled'
    save(obj) { |r| return_success(r.as_pos) }
  end

  # Mark a reminder dispatched (would trigger WhatsApp/SMS/email in production).
  def send_now
    item.status = 'sent'
    save(item) { return_success(item.as_pos) }
  end

  def item(id = rp[:id]) = (@item ||= scoped[id] || return_errors!('Reminder not found', 404))

  def self.fields
    { save: %i[plot_id plot_no owner_name amount channel scheduled_for status] }
  end
end
