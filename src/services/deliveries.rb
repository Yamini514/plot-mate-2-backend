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
    save(obj) do |d|
      App::Audit.record('delivery.entry', entity: d, client_id: d.client_id,
                        summary: "Delivery #{d.code} (#{d.courier}) received for plot #{d.plot_no}")
      notify_owner(d, title: 'A delivery is waiting at the gate',
                   body: "#{d.courier || 'A courier'} delivery for your plot is held at the gate.")
      return_success(d.as_pos)
    end
  end

  # Hand the package to the resident → log exit + notify.
  def handover
    item.handover!
    App::Audit.record('delivery.exit', entity: item, client_id: item.client_id,
                      summary: "Delivery #{item.code} handed over for plot #{item.plot_no}")
    notify_owner(item, title: 'Delivery collected',
                 body: "Your #{item.courier || 'courier'} delivery was handed over.")
    return_success(item.as_pos)
  end

  def item(id = rp[:id]) = (@item ||= scoped[id] || return_errors!('Delivery not found', 404))

  private

  # Notify the plot owner's login (if any) about a delivery event.
  def notify_owner(d, title:, body:)
    return if d.plot_no.to_s.empty?
    owner = App::Models::User.where(client_id: current_client_id, role: App::Models::User::ROLES[:member])
                             .all.find { |u| u.extras&.dig('plot_no').to_s == d.plot_no.to_s }
    return unless owner
    App::Notify.create(user_id: owner.id, client_id: current_client_id, kind: 'delivery',
                       title: title, body: body, link: '/member', entity: d)
  rescue => e
    App.logger.error("delivery notify: #{e.message}")
  end

  def self.fields
    { save: %i[courier agent resident_name plot_no status photo_url mobile] }
  end
end
