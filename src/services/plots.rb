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
    obj.recompute_dues! if apply_dues?
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
      item.recompute_dues!
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
          plot.recompute_dues!
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

  # Aggregate counts/dues for the registry header cards.
  def summary
    ds = scoped
    return_success(
      total_plots:   ds.count,
      paid_count:    ds.where(payment_status: 'paid').count,
      pending_count: ds.where(payment_status: 'pending').count,
      unknown_count: ds.where(payment_status: 'unknown').count,
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

  def self.fields
    { save: %i[plot_no owner_name phone email size_sqyd phase membership payment_status active] }
  end
end
