require 'time' # Time.parse for reservation expiry

class App::Services::Plots < App::Services::Base
  def model = Plot

  def list
    ds = scoped.order(Sequel.asc(:plot_no))
    ds = ds.where(payment_status: qs[:status]) if qs[:status].present? && qs[:status] != 'all'
    ds = ds.where(phase: qs[:phase])           if qs[:phase].present?  && qs[:phase]  != 'all'
    if qs[:search].present?
      term = "%#{qs[:search]}%"
      ds = ds.where { Sequel.ilike(:plot_no, term) | Sequel.ilike(:owner_name, term) | Sequel.ilike(:phone, term) }
    end
    count = ds.count
    return_success(ds.offset(offset).limit(limit).all.map(&:as_pos),
                   total_pages: (count / page_size.to_f).ceil)
  end

  def get
    return_success(item.as_pos)
  end

  def create
    obj = model.new(data_for(:save))
    obj.client_id = current_client_id
    # Maintenance dues are NOT auto-applied on create. A new plot starts with a
    # zero balance and only gets billed when the admin explicitly opts in via the
    # `apply_dues` flag (or later through the billing module).
    obj.set_base_pay!(base_pay_paise(obj)) if apply_dues?
    save(obj) { |p| return_success(p.as_pos) }
  end

  def update
    data = data_for(:save)
    item.set_fields(data, data.keys)
    # Marking a plot paid clears its balance. Otherwise the due never changes on
    # its own — the admin must explicitly re-apply it (apply_dues), so editing a
    # plot's size won't silently re-introduce a charge.
    if data['payment_status'] == 'paid'
      item.amount_due_paise = 0
    elsif apply_dues?
      item.set_base_pay!(base_pay_paise(item))
    end
    save(item) { |p| return_success(p.as_pos) }
  end

  # Bulk import from an uploaded spreadsheet (parsed to JSON rows on the client).
  # Upserts each row by plot_no within the tenant: existing plots are updated,
  # new plot numbers are created. Rows are processed independently so one bad
  # row never blocks the rest — the response reports created/updated counts and
  # a per-row error list the UI can surface.
  STATUSES = %w[paid pending unknown].freeze
  MAX_IMPORT_ROWS = 1000

  def import_rows
    rows = params[:rows]
    return_errors!('No rows to import', 400) unless rows.is_a?(Array) && rows.any?
    return_errors!("Too many rows (max #{MAX_IMPORT_ROWS})", 400) if rows.size > MAX_IMPORT_ROWS

    apply  = apply_dues?
    created = 0
    updated = 0
    errors  = []

    rows.each_with_index do |row, i|
      plot_no = row[:plot_no].to_s.strip
      if plot_no.empty?
        errors << { row: i + 1, plot_no: nil, message: 'Missing plot number' }
        next
      end

      attrs = {
        owner_name:     row[:owner_name].presence,
        phone:          row[:phone].presence,
        email:          row[:email].presence,
        size_sqyd:      (row[:size_sqyd].present? ? row[:size_sqyd].to_i : nil),
        phase:          row[:phase].presence,
        payment_status: (STATUSES.include?(row[:payment_status].to_s) ? row[:payment_status] : nil)
      }.compact

      begin
        plot   = scoped.where(plot_no: plot_no).first
        is_new = plot.nil?
        if is_new
          plot = model.new(attrs)
          plot.plot_no        = plot_no
          plot.client_id      = current_client_id
          plot.payment_status = 'pending' if plot.payment_status.blank?
        else
          plot.set_fields(attrs, attrs.keys) unless attrs.empty?
        end

        # Keep dues consistent with the chosen status / opt-in, mirroring create/update.
        if plot.payment_status == 'paid'
          plot.amount_due_paise = 0
        elsif apply
          plot.set_base_pay!(base_pay_paise(plot))
        end

        unless plot.valid?
          errors << { row: i + 1, plot_no: plot_no, message: plot.errors.full_messages.join(', ') }
          next
        end

        plot.save
        is_new ? created += 1 : updated += 1
      rescue => e
        App.logger.error("plot import row #{i + 1}: #{e.message}")
        errors << { row: i + 1, plot_no: plot_no, message: e.message }
      end
    end

    return_success(created: created, updated: updated, skipped: errors.size, errors: errors)
  end

  # Apply (regenerate) base pay across many plots at once, using the association's
  # configured rule. `status` narrows the set (all|pending|unknown); paid plots
  # are always cleared to zero by set_base_pay!. Idempotent — safe to re-run.
  def apply_base_pay
    cfg  = base_pay_config
    zero = cfg[:mode] == 'per_plot' ? cfg[:flat_paise].zero? : cfg[:rate_paise].zero?
    return_errors!('Set a base-pay rate under Settings → Fees & Dues first', 400) if zero

    ds = scoped
    ds = ds.where(payment_status: params[:status]) if params[:status].present? && params[:status] != 'all'

    count = 0
    total = 0
    App.db.transaction do
      ds.each do |plot|
        plot.set_base_pay!(base_pay_paise(plot))
        plot.save_changes
        count += 1
        total += plot.amount_due_paise.to_i
      end
    end
    return_success(count: count, mode: cfg[:mode], total: total / 100)
  end

  # Bulk-create empty (available, unowned) plots from a list of plot numbers the
  # admin reads off the uploaded site plan — the bridge that turns the numbers
  # printed on a raster map into real records the registration selector can list.
  # Existing numbers are skipped (never overwritten), so it's safe to re-run as
  # more of the plan is transcribed. Body: { plot_nos: [...], phase, size_sqyd }.
  MAX_GENERATE = 2000

  def generate_plots
    nos = Array(params && params[:plot_nos]).map { |n| n.to_s.strip }.reject(&:empty?).uniq
    return_errors!('No plot numbers provided', 400) if nos.empty?
    return_errors!("Too many plots at once (max #{MAX_GENERATE})", 400) if nos.size > MAX_GENERATE

    phase = params[:phase].presence
    size  = params[:size_sqyd].present? ? params[:size_sqyd].to_i : nil
    existing  = scoped.where(plot_no: nos).select_map(:plot_no)
    to_create = nos - existing

    created = 0
    errors  = []
    App.db.transaction do
      to_create.each do |no|
        # Empty plots start available + unowned with an unknown payment state, so
        # the map colours them green ("available") rather than amber ("pending").
        plot = model.new(plot_no: no, phase: phase, size_sqyd: size,
                         status: 'available', payment_status: 'unknown')
        plot.client_id = current_client_id
        if plot.valid?
          plot.save
          created += 1
        else
          errors << { plot_no: no, message: plot.errors.full_messages.join(', ') }
        end
      end
    end
    return_success(created: created, skipped: existing.size, errors: errors)
  end

  # Register an owner against an existing, unowned plot — the admin "register"
  # step. Fills in the owner's contact details, marks the plot booked and leaves
  # it unverified, pending the admin's explicit approval (see #approve). Refuses
  # a plot that already has an owner so a registration can never silently
  # overwrite one. The plot must already exist (it comes from the imported map /
  # registry); this never creates a new plot number.
  def register_owner
    return_errors!("#{item.plot_no} already has a registered owner — edit it instead.", 422) if item.owner_name.to_s.strip != ''

    data = data_for(:register)
    item.set_fields(data, data.keys) unless data.empty?
    return_errors!('Owner name is required to register a plot', 400) if item.owner_name.to_s.strip.empty?

    item.status     = 'booked'
    item.membership = 'unverified'
    save(item) { |p| return_success(p.as_pos) }
  end

  # Approve a registered owner: flips membership to verified. The lifecycle
  # status is left as-is (a registered plot stays "booked") — verification is a
  # membership state, not a status change. Requires the plot to actually have an
  # owner so an empty plot can't be "approved".
  def approve
    return_errors!('Register an owner before approving this plot', 422) if item.owner_name.to_s.strip == ''
    item.membership = 'verified'
    save(item) { |p| return_success(p.as_pos) }
  end

  # --- multiple owners (joint ownership) ----------------------------------
  def owners
    rows  = owner_rows
    uids  = rows.map(&:user_id).compact.uniq
    active = uids.any? ? User.where(id: uids).select_hash(:id, :active) : {}
    return_success(rows.map { |o| o.as_pos.merge(login_active: o.user_id ? active[o.user_id] : nil) })
  end

  def add_owner
    validate!(
      'name'  => App::Validate.text(params[:name], min: 2, max: 120, label: 'Owner name'),
      'phone' => App::Validate.phone(params[:phone]),
      'email' => App::Validate.email(params[:email], required: false)
    )
    first = owner_rows.empty?
    o = PlotOwner.create(
      client_id: current_client_id, plot_id: item.id, user_id: params[:user_id],
      name: params[:name].to_s.strip, phone: params[:phone], email: params[:email],
      share: params[:share], primary_owner: first || !!params[:primary], created_by: App.cu.id
    )
    sync_primary!(o) if o.primary_owner
    App::Audit.record('plot.owner.add', entity: item, client_id: current_client_id,
                      summary: "Added owner #{o.name} to #{item.plot_no}")
    return_success(owner_rows(reload: true).map(&:as_pos))
  end

  def remove_owner
    o = owner!(rp[:owner])
    was_primary = o.primary_owner
    o.destroy
    if was_primary
      nxt = owner_rows(reload: true).first
      nxt ? (nxt.update(primary_owner: true); sync_primary!(nxt)) : clear_primary!
    end
    App::Audit.record('plot.owner.remove', entity: item, client_id: current_client_id,
                      summary: "Removed owner #{o.name} from #{item.plot_no}")
    return_success(owner_rows(reload: true).map(&:as_pos))
  end

  def set_primary
    o = owner!(rp[:owner])
    PlotOwner.where(client_id: current_client_id, plot_id: item.id).update(primary_owner: false)
    o.update(primary_owner: true)
    sync_primary!(o)
    App::Audit.record('plot.owner.primary', entity: item, client_id: current_client_id,
                      summary: "Set #{o.name} as primary owner of #{item.plot_no}")
    return_success(owner_rows(reload: true).map(&:as_pos))
  end

  # --- reservation / merge / split ----------------------------------------
  # Place a temporary hold on an available plot.
  def reserve
    return_errors!('Only an available plot can be reserved', 422) unless %w[available].include?(item.status)
    until_at = params[:reserved_until].present? ? (Time.parse(params[:reserved_until].to_s) rescue nil) : nil
    item.set(status: 'reserved', reserved_until: until_at, reserved_for: params[:reserved_for])
    save(item) do |p|
      App::Audit.record('plot.reserve', entity: p, client_id: current_client_id,
                        summary: "Reserved #{p.plot_no}#{params[:reserved_for] ? " for #{params[:reserved_for]}" : ''}")
      return_success(p.as_pos)
    end
  end

  def unreserve
    item.set(status: 'available', reserved_until: nil, reserved_for: nil)
    save(item) do |p|
      App::Audit.record('plot.unreserve', entity: p, client_id: current_client_id, summary: "Released hold on #{p.plot_no}")
      return_success(p.as_pos)
    end
  end

  # Merge several plots into a target: their areas roll up and they're retired
  # (inactive, merged_into_id set). Owned plots can't be merged.
  def merge_plots
    target = scoped.where(id: params[:target_id].to_i).first || return_errors!('Target plot not found', 404)
    ids = Array(params[:source_ids]).map(&:to_i).reject { |i| i == target.id }
    sources = scoped.where(id: ids).all
    return_errors!('Pick at least one source plot', 422) if sources.empty?
    if sources.any? { |s| s.owner_name.to_s.strip != '' }
      return_errors!('Cannot merge a plot that already has an owner', 422)
    end
    App.db.transaction do
      added = sources.sum { |s| s.size_sqyd.to_i }
      target.update(size_sqyd: target.size_sqyd.to_i + added)
      sources.each { |s| s.update(active: false, status: 'blocked', merged_into_id: target.id) }
    end
    App::Audit.record('plot.merge', entity: target, client_id: current_client_id,
                      summary: "Merged #{sources.size} plot(s) into #{target.plot_no}")
    return_success(target.as_pos.merge(merged: sources.size))
  end

  # Split a plot into N new child plots, then retire the parent.
  def split_plot
    parent = item
    return_errors!('Cannot split a plot that has an owner', 422) if parent.owner_name.to_s.strip != ''
    children = Array(params[:children]) # [{plot_no, size_sqyd}]
    return_errors!('Provide child plots', 422) if children.empty?
    created = []
    App.db.transaction do
      children.each do |c|
        no = c[:plot_no].to_s.strip
        next if no.empty? || scoped.where(plot_no: no).count.positive?
        child = model.new(plot_no: no, phase: parent.phase, size_sqyd: c[:size_sqyd].to_i,
                          status: 'available', payment_status: 'unknown', split_from_id: parent.id)
        child.client_id = current_client_id
        child.save
        created << child.plot_no
      end
      parent.update(active: false, status: 'blocked')
    end
    App::Audit.record('plot.split', entity: parent, client_id: current_client_id,
                      summary: "Split #{parent.plot_no} into #{created.size} plot(s)")
    return_success(parent: parent.plot_no, created: created)
  end

  # Aggregate counts/dues for the registry header cards.
  def summary
    ds = scoped
    # Lifecycle-status tallies (available/booked/sold/blocked) for the map's
    # summary cards. A null status (rows created before 0033) counts as available.
    status_counts = ds.group_and_count(:status).all.each_with_object(Hash.new(0)) do |row, h|
      h[(row[:status] || 'available')] += row[:count]
    end
    return_success(
      total_plots:   ds.count,
      paid_count:    ds.where(payment_status: 'paid').count,
      pending_count: ds.where(payment_status: 'pending').count,
      unknown_count: ds.where(payment_status: 'unknown').count,
      available_count: status_counts['available'],
      booked_count:    status_counts['booked'],
      sold_count:      status_counts['sold'],
      blocked_count:   status_counts['blocked'],
      outstanding:   (ds.where(payment_status: 'pending').sum(:amount_due_paise) || 0) / 100
    )
  end

  # Scope single-record lookups to the caller's tenant.
  def item(id = rp[:id])
    @item ||= scoped[id] || return_errors!('Plot not found', 404)
  end

  def owner_rows(reload: false)
    @owner_rows = nil if reload
    @owner_rows ||= PlotOwner.where(client_id: current_client_id, plot_id: item.id)
                             .order(Sequel.desc(:primary_owner), :name).all
  end

  def owner!(id)
    PlotOwner[client_id: current_client_id, plot_id: item.id, id: id.to_i] ||
      return_errors!('Owner not found', 404)
  end

  # Keep the denormalised primary-owner fields on the plot in sync.
  def sync_primary!(o)
    item.owner_name = o.name
    item.phone = o.phone
    item.email = o.email
    item.status = 'booked' if item.status == 'available'
    item.save_changes
  end

  def clear_primary!
    item.set(owner_name: nil, phone: nil, email: nil)
    item.save_changes
  end

  # Did the admin explicitly ask to apply maintenance dues for this request?
  def apply_dues?
    v = params && params[:apply_dues]
    [true, 'true', 1, '1'].include?(v)
  end

  # The association's base-pay rule, read live from its settings (no hardcoded
  # rate). `mode` selects per-unit (size × rate) or flat (one amount per plot).
  def base_pay_config
    @base_pay_config ||= begin
      s = (Client[current_client_id]&.settings || {})
      {
        mode:       s['base_pay_mode'] == 'per_plot' ? 'per_plot' : 'per_sqyd',
        rate_paise: ((s['rate_per_sqyd'] || 0).to_f * 100).round,
        flat_paise: ((s['base_pay_flat'] || 0).to_f * 100).round
      }
    end
  end

  # Base pay (paise) owed by a single plot under the current rule.
  def base_pay_paise(plot)
    cfg = base_pay_config
    cfg[:mode] == 'per_plot' ? cfg[:flat_paise] : plot.size_sqyd.to_i * cfg[:rate_paise]
  end

  def self.fields
    {
      save: %i[plot_no owner_name phone email size_sqyd phase membership status payment_status active],
      # Registration only touches the owner's own details — never the plot number,
      # status or membership (those are set explicitly in register_owner).
      register: %i[owner_name phone email size_sqyd phase]
    }
  end
end
