class App::Services::LostFound < App::Services::Base
  # Lost & found register. Tenant-scoped.
  def model = LostFoundItem

  def list
    ds = scoped.order(Sequel.desc(:created_at))
    ds = ds.where(status: qs[:status]) if qs[:status].present? && qs[:status] != 'all'
    if qs[:search].present?
      term = "%#{qs[:search]}%"
      ds = ds.where { Sequel.ilike(:title, term) | Sequel.ilike(:description, term) }
    end
    return_success(ds.all.map(&:as_pos), counts: counts)
  end

  def get = return_success(item.as_pos)

  def create
    validate!('title' => App::Validate.text(params[:title], min: 2, max: 160, label: 'Title'))
    obj = model.new(data_for(:save))
    obj.client_id = current_client_id
    obj.code ||= "LF-#{1000 + scoped.count + 1}"
    obj.status ||= 'open'
    obj.created_by = App.cu.id
    save(obj) { |i| return_success(i.as_pos) }
  end

  def update
    item.set_fields(data_for(:save), data_for(:save).keys)
    save(item) { |i| return_success(i.as_pos) }
  end

  # Record a claim against an item.
  def claim
    validate!('claimant_name' => App::Validate.text(params[:claimant_name], min: 2, max: 120, label: 'Claimant'),
              'claimant_phone' => App::Validate.phone(params[:claimant_phone]))
    item.set(status: 'claimed', claimant_name: params[:claimant_name], claimant_phone: params[:claimant_phone])
    save(item) do |i|
      App::Audit.record('lostfound.claim', entity: i, client_id: current_client_id, summary: "Claimed #{i.code} (#{i.title})")
      return_success(i.as_pos)
    end
  end

  def close
    item.set(status: 'closed')
    save(item) { |i| return_success(i.as_pos) }
  end

  def item(id = rp[:id]) = (@item ||= scoped[id] || return_errors!('Item not found', 404))

  private

  def counts
    { all: scoped.count, open: scoped.where(status: 'open').count,
      claimed: scoped.where(status: 'claimed').count, closed: scoped.where(status: 'closed').count }
  end

  def self.fields
    { save: %i[title description photo_url found_location status] }
  end
end
