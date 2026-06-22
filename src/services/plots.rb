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
    { save: %i[plot_no owner_name phone email size_sqyd phase membership status payment_status active] }
  end
end
