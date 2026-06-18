class App::Services::Amenities < App::Services::Base
  def model = Amenity

  def list = return_success(scoped.order(Sequel.asc(:name)).all.map(&:as_pos))

  def get = return_success(item.as_pos)

  def create
    obj = model.new(coerced)
    obj.client_id = current_client_id
    obj.code ||= "AM-#{scoped.count + 1}"
    save(obj) { |a| return_success(a.as_pos) }
  end

  def update
    item.set_fields(coerced, coerced.keys)
    save(item) { |a| return_success(a.as_pos) }
  end

  def item(id = rp[:id]) = (@item ||= scoped[id] || return_errors!('Amenity not found', 404))

  private

  def coerced
    @coerced ||= begin
      d = data_for(:save)
      d['hourly_rate_paise'] = (d.delete('hourly_rate').to_f * 100).round if d.key?('hourly_rate')
      d
    end
  end

  def self.fields
    { save: %i[name description capacity hourly_rate icon status] }
  end
end
