class App::Services::Staff < App::Services::Base
  def model = App::Models::Staff

  def list
    ds = scoped.order(Sequel.asc(:name))
    ds = ds.where(kind: qs[:kind])     if qs[:kind].present?   && qs[:kind]   != 'all'
    ds = ds.where(status: qs[:status]) if qs[:status].present? && qs[:status] != 'all'
    return_success(ds.all.map(&:as_pos))
  end

  def get = return_success(item.as_pos)

  def create
    obj = model.new(coerced)
    obj.client_id = current_client_id
    obj.code ||= "ST-#{scoped.count + 1}"
    save(obj) { |s| return_success(s.as_pos) }
  end

  def update
    item.set_fields(coerced, coerced.keys)
    save(item) { |s| return_success(s.as_pos) }
  end

  def item(id = rp[:id]) = (@item ||= scoped[id] || return_errors!('Staff not found', 404))

  private

  def coerced
    @coerced ||= begin
      d = data_for(:save)
      d['monthly_salary_paise'] = (d.delete('monthly_salary').to_f * 100).round if d.key?('monthly_salary')
      d['kind'] = d.delete('type') if d.key?('type')
      d
    end
  end

  def self.fields
    { save: %i[name role phone monthly_salary joined_on status type] }
  end
end
