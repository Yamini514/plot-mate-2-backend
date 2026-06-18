class App::Services::Complaints < App::Services::Base
  def model = Complaint

  def list
    ds = scoped.order(Sequel.desc(:created_at))
    ds = ds.where(status: qs[:status])     if qs[:status].present? && qs[:status] != 'all'
    ds = ds.where(priority: qs[:priority]) if qs[:priority].present?
    ds = ds.where(raised_by_user_id: App.cu.id) if qs[:mine] == 'true'
    if qs[:search].present?
      term = "%#{qs[:search]}%"
      ds = ds.where { Sequel.ilike(:title, term) | Sequel.ilike(:code, term) | Sequel.ilike(:raised_by, term) }
    end
    count = ds.count
    return_success(ds.offset(offset).limit(limit).all.map(&:as_pos),
                   total_pages: (count / page_size.to_f).ceil, counts: counts_by_status)
  end

  def get
    return_success(item.as_pos)
  end

  def create
    obj = model.new(data_for(:save))
    obj.client_id = current_client_id
    obj.code ||= next_code
    obj.status = 'open'                                   # new complaints start open
    obj.raised_by ||= App.cu.user_obj.full_name
    obj.raised_by_user_id ||= App.cu.id
    obj.plot_no ||= App.cu.user_obj.extras&.dig('plot_no')
    save(obj) { |c| return_success(c.as_pos) }
  end

  def update
    data = data_for(:save)
    item.set_fields(data, data.keys)
    save(item) { |c| return_success(c.as_pos) }
  end

  def assign
    item.assigned_to    = params[:assigned_to].presence || 'Maintenance Team'
    item.assigned_phone = params[:assigned_phone] if params.key?(:assigned_phone)
    item.assigned_email = params[:assigned_email] if params.key?(:assigned_email)
    item.assigned_to_user_id = params[:assigned_to_user_id] if params.key?(:assigned_to_user_id)
    item.status = 'in_progress' if item.status == 'open'
    save(item) { |c| return_success(c.as_pos) }
  end

  def resolve
    item.status = 'resolved'
    save(item) { |c| return_success(c.as_pos) }
  end

  def summary
    ds = scoped
    return_success(
      total:       ds.count,
      open:        ds.where(status: 'open').count,
      in_progress: ds.where(status: 'in_progress').count,
      resolved:    ds.where(status: 'resolved').count,
      high:        ds.where(priority: 'high').count
    )
  end

  def item(id = rp[:id])
    @item ||= scoped[id] || return_errors!('Complaint not found', 404)
  end

  private

  def counts_by_status
    c = scoped.group_and_count(:status).all
              .each_with_object({}) { |r, h| h[r[:status]] = r[:count] }
    c['all'] = scoped.count
    c
  end

  def next_code
    "CMP-#{format('%03d', scoped.count + 1)}"
  end

  def self.fields
    { save: %i[title description category priority plot_no status assigned_to assigned_phone assigned_email assigned_to_user_id] }
  end
end
