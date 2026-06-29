class App::Services::Visitors < App::Services::Base
  def model = Visitor

  def list
    ds = scoped.order(Sequel.desc(:created_at))
    ds = ds.where(status: qs[:status]) if qs[:status].present? && qs[:status] != 'all'
    if qs[:search].present?
      term = "%#{qs[:search]}%"
      ds = ds.where { Sequel.ilike(:name, term) | Sequel.ilike(:plot_no, term) | Sequel.ilike(:resident_name, term) }
    end
    return_success(ds.all.map(&:as_pos))
  end

  def get = return_success(item.as_pos)

  # Gate pass-code lookup: a guard enters/scans the visitor's pass code to pull
  # up their pre-approved pass and verify identity before allowing entry.
  def lookup
    code = params[:pass_code].to_s.strip
    return_errors!('Enter a pass code', 422) if code.empty?
    v = scoped.where(pass_code: code).first || return_errors!('No pass found for that code', 404)
    return_success(v.as_pos)
  end

  def create
    obj = model.new(data_for(:save))
    obj.client_id = current_client_id
    obj.code ||= "VIS-#{2400 + scoped.count + 1}"
    obj.status ||= 'pending'
    # Walk-in visitors registered at the gate get a pass code too.
    obj.pass_code ||= Visitor.gen_pass_code
    save(obj) do |v|
      App::Audit.record('visitor.register', entity: v, client_id: v.client_id,
                        summary: "Registered visitor #{v.name} for plot #{v.plot_no}")
      return_success(v.as_pos)
    end
  end

  def update
    data = data_for(:save)
    item.set_fields(data, data.keys)
    save(item) { |v| return_success(v.as_pos) }
  end

  # Guard action: approve | reject | checkin | checkout
  ACTION_AUDIT = { 'checkin' => 'visitor.entry', 'checkout' => 'visitor.exit',
                   'approve' => 'visitor.approve', 'reject' => 'visitor.reject' }.freeze

  def action
    act = params[:action].to_s
    return_errors!('Invalid action', 400) unless item.apply_action!(act)  # persists internally
    if (a = ACTION_AUDIT[act])
      App::Audit.record(a, entity: item, client_id: item.client_id,
                        summary: "#{act.capitalize} — #{item.name} (plot #{item.plot_no})")
    end
    return_success(item.as_pos)
  end

  def item(id = rp[:id]) = (@item ||= scoped[id] || return_errors!('Visitor not found', 404))

  def self.fields
    { save: %i[name phone resident_name plot_no purpose vehicle_no status] }
  end
end
