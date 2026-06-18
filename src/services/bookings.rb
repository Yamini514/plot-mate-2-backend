class App::Services::Bookings < App::Services::Base
  def model = Booking

  def list
    ds = scoped.order(Sequel.desc(:date), Sequel.desc(:id))
    ds = ds.where(status: qs[:status]) if qs[:status].present? && qs[:status] != 'all'
    ds = ds.where(booked_by_user_id: App.cu.id) if qs[:mine] == 'true'
    return_success(ds.all.map(&:as_pos))
  end

  def get = return_success(item.as_pos)

  # Member books an amenity; amount derived from the amenity's rate if absent.
  def create
    amenity = Amenity[client_id: current_client_id, id: params[:amenity_id]] ||
              return_errors!('Amenity not found', 404)
    amount_paise = params[:amount].present? ? (params[:amount].to_f * 100).round : (amenity.hourly_rate_paise || 0)
    obj = model.new(
      client_id: current_client_id, code: "BK-#{scoped.count + 1}",
      amenity_id: amenity.id, amenity_name: amenity.name,
      booked_by: App.cu.user_obj.full_name, booked_by_user_id: App.cu.id,
      plot_no: App.cu.user_obj.extras&.dig('plot_no'),
      date: params[:date], slot: params[:slot], status: 'pending', amount_paise: amount_paise
    )
    save(obj) { |b| return_success(b.as_pos) }
  end

  # Admin confirm / cancel.
  def set_status
    new_status = params[:status].to_s
    return_errors!('Invalid status', 400) unless Booking::STATUSES.include?(new_status)
    item.status = new_status
    save(item) { |b| return_success(b.as_pos) }
  end

  def item(id = rp[:id]) = (@item ||= scoped[id] || return_errors!('Booking not found', 404))
end
