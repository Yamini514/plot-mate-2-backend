class App::Services::Invoices < App::Services::Base
  def model = Invoice

  # ---- read ---------------------------------------------------------------
  def list
    ds = scoped.order(Sequel.desc(:issued_on), Sequel.desc(:id))
    ds = ds.where(status: qs[:status]) if qs[:status].present? && qs[:status] != 'all'
    if qs[:search].present?
      term = "%#{qs[:search]}%"
      ds = ds.where do
        Sequel.ilike(:number, term) | Sequel.ilike(:owner_name, term) |
          Sequel.ilike(:property, term) | Sequel.ilike(:plan_name, term)
      end
    end
    count = ds.count
    return_success(ds.offset(offset).limit(limit).all.map(&:as_pos),
                   total_pages: (count / page_size.to_f).ceil, counts: status_counts)
  end

  def get
    inv = item
    return_success(inv.as_pos.merge(
      adjustments: InvoiceAdjustment.where(invoice_id: inv.id).order(:created_at).all.map(&:as_pos),
      payments:    Payment.where(invoice_id: inv.id).order(Sequel.desc(:paid_on)).all.map(&:as_pos)
    ))
  end

  # ---- write --------------------------------------------------------------
  def create
    obj = model.new(data_for(:save))
    obj.client_id = current_client_id
    obj.number ||= next_invoice_number
    obj.issued_on ||= Date.today
    obj.recompute!
    save(obj) { |i| return_success(i.as_pos) }
  end

  def update
    data = data_for(:save)
    item.set_fields(data, data.keys)
    item.recompute!
    save(item) { |i| return_success(i.as_pos) }
  end

  # Recurring generation: one invoice per active plot for the given plan/period.
  def generate
    plan = Plan[client_id: current_client_id, id: params[:plan_id]] ||
           return_errors!('Plan not found', 404)
    period = params[:period].presence || default_period(plan)
    due    = parse_date(params[:due_date]) || Date.today + 10
    created = 0

    App.db.transaction do
      Plot.where(client_id: current_client_id, active: true).each do |plot|
        next if Invoice.where(client_id: current_client_id, plot_id: plot.id,
                              plan_id: plan.id, period: period).count.positive?
        tax = (plan.amount_paise * (plan.tax_percent || 0)) / 100
        inv = Invoice.new(
          client_id: current_client_id, plot_id: plot.id, plan_id: plan.id,
          number: next_invoice_number, owner_name: plot.owner_name,
          property: plot.plot_no, property_type: 'Plot', plan_name: plan.name,
          category: plan.category, period: period,
          amount_paise: plan.amount_paise, tax_paise: tax,
          status: 'generated', issued_on: Date.today, due_date: due
        )
        inv.recompute!
        inv.save
        created += 1
      end
    end
    App::Audit.record('invoice.generate', entity_type: 'Invoice', client_id: current_client_id,
                      summary: "Generated #{created} invoice(s) for #{period}",
                      meta: { plan_id: plan.id, period: period })
    return_success(count: created, period: period)
  end

  # One-off charge to a single owner — for fees that don't apply fleet-wide
  # (transfer, NOC, penalty, ad-hoc). Bills the plan's amount to one plot.
  def charge
    plot = Plot[client_id: current_client_id, id: params[:plot_id]] ||
           return_errors!('Plot not found', 404)
    plan = Plan[client_id: current_client_id, id: params[:plan_id]] ||
           return_errors!('Fee not found', 404)
    period = params[:period].presence || default_period(plan)
    due    = parse_date(params[:due_date]) || Date.today + 10
    tax    = (plan.amount_paise * (plan.tax_percent || 0)) / 100

    inv = Invoice.new(
      client_id: current_client_id, plot_id: plot.id, plan_id: plan.id,
      number: next_invoice_number, owner_name: plot.owner_name,
      property: plot.plot_no, property_type: 'Plot', plan_name: plan.name,
      category: plan.category, period: period,
      amount_paise: plan.amount_paise, tax_paise: tax,
      status: 'generated', issued_on: Date.today, due_date: due
    )
    inv.recompute!
    save(inv) do |i|
      App::Audit.record('invoice.charge', entity: i, client_id: current_client_id,
                        summary: "Charged #{plan.name} to #{plot.plot_no} (#{format_currency(i.total_paise)})")
      return_success(i.as_pos)
    end
  end

  # Bulk workflow transition (send / cancel / generate / mark-paid).
  def set_status
    ids = Array(params[:ids] || rp[:id]).compact.map(&:to_i)
    new_status = params[:status].to_s
    return_errors!('Invalid status', 400) unless Invoice::STATUSES.include?(new_status)

    affected = 0
    App.db.transaction do
      scoped.where(id: ids).each do |inv|
        if new_status == 'paid' && inv.balance_paise.to_i.positive?
          # mark-paid records a real payment so treasury reconciles
          Payment.record!(invoice: inv, amount_paise: inv.balance_paise,
                          mode: params[:mode].presence || 'cash',
                          note: 'Bulk mark-paid')
        else
          inv.status = new_status
          inv.save_changes
        end
        affected += 1
      end
    end
    return_success(count: affected)
  end

  # Apply each overdue invoice's plan late-fee rule (idempotent per invoice).
  # Honours a configurable grace period (Settings → penalty_grace_days): the
  # penalty only lands once an invoice is overdue by more than the grace window.
  def apply_late_fees
    grace  = penalty_grace_days
    cutoff = Date.today - grace
    applied = 0
    scoped.where(status: Invoice::OPEN_STATUSES)
          .where { due_date < cutoff }.each do |inv|
      applied += 1 if inv.apply_late_fee!
    end
    return_success(applied: applied, grace_days: grace)
  end

  # Accrue one month of interest on every overdue invoice at the venture's
  # configured monthly rate (Settings → interest_percent_monthly). Idempotent
  # per calendar month per invoice (safe to run repeatedly / from the scheduler).
  def apply_interest
    rate = interest_rate
    return_errors!('Set a monthly interest rate in Settings → Fees first', 422) if rate <= 0
    applied = 0
    scoped.where(status: Invoice::OPEN_STATUSES).each do |inv|
      applied += 1 if inv.apply_interest!(rate)
    end
    App::Audit.record('invoice.apply_interest', entity_type: 'Invoice', client_id: current_client_id,
                      summary: "Accrued interest on #{applied} invoice(s)", meta: { rate_percent: rate })
    return_success(applied: applied, rate_percent: rate)
  end

  # Owner-wise demand statement: every invoice for one plot, with running
  # totals — the printable "what you owe" summary.
  def demand_statement
    plot = Plot[client_id: current_client_id, id: (qs[:plot_id] || params[:plot_id])] ||
           return_errors!('Plot not found', 404)
    invs = scoped.where(plot_id: plot.id).order(Sequel.desc(:issued_on)).all
    billed      = invs.sum(&:total_paise)
    paid        = invs.sum { |i| i.paid_paise || 0 }
    outstanding = invs.reject { |i| i.status == 'cancelled' }.sum { |i| i.balance_paise || 0 }
    return_success(
      plot:    { id: plot.id, plot_no: plot.plot_no, owner_name: plot.owner_name,
                 email: plot.email, phone: plot.phone },
      invoices: invs.map(&:as_pos),
      totals:  { billed: billed / 100, paid: paid / 100, outstanding: outstanding / 100 },
      generated_on: Date.today
    )
  end

  # Fund rollup: money collected (credits) grouped by fee category, so corpus,
  # maintenance, water, etc. funds can be tracked separately.
  def fund_summary
    rows = Transaction.where(client_id: current_client_id, direction: 'credit')
                      .group(:category)
                      .select(:category, Sequel.function(:sum, :amount_paise).as(:total)).all
    by_cat = rows.map { |r| { category: r[:category] || 'other', collected: (r[:total] || 0) / 100 } }
                 .sort_by { |h| -h[:collected] }
    return_success(
      by_category:      by_cat,
      corpus_collected: (by_cat.find { |h| h[:category] == 'corpus' }&.dig(:collected) || 0),
      total_collected:  by_cat.sum { |h| h[:collected] }
    )
  end

  # Waiver / discount / credit — reduces balance, logged with reason + author.
  def adjust
    inv = item
    kind = params[:kind].presence || 'waiver'
    amount_paise = (params[:amount].to_f * 100).round
    return_errors!('amount must be positive', 400) if amount_paise <= 0

    App.db.transaction do
      InvoiceAdjustment.create(client_id: inv.client_id, invoice_id: inv.id,
                               kind: kind, amount_paise: amount_paise,
                               reason: params[:reason])
      inv.discount_paise = (inv.discount_paise || 0) + amount_paise
      inv.recompute!
      inv.save_changes
    end
    App::Audit.record('invoice.adjust', entity: inv, client_id: current_client_id,
                      summary: "#{kind.capitalize} #{format_currency(amount_paise)} on #{inv.number}",
                      meta: { kind: kind, reason: params[:reason] })
    return_success(inv.as_pos)
  end

  # ---- analytics ----------------------------------------------------------
  def summary
    rows = scoped.exclude(status: 'cancelled').all
    billed    = rows.sum(&:total_paise)
    collected = rows.sum { |r| r.paid_paise || 0 }
    pending   = rows.select { |r| %w[generated sent partially_paid].include?(r.status) }
                    .sum { |r| r.balance_paise || 0 }
    overdue   = rows.select { |r| r.status == 'overdue' }.sum { |r| r.balance_paise || 0 }
    return_success(
      total_billed:    billed / 100,
      total_collected: collected / 100,
      pending:         pending / 100,
      overdue:         overdue / 100,
      collection_rate: billed.zero? ? 0 : (collected * 1000 / billed) / 10.0,
      invoice_count:   rows.length,
      unpaid_count:    rows.count { |r| %w[generated sent partially_paid overdue].include?(r.status) },
      defaulters:      rows.count { |r| r.status == 'overdue' }
    )
  end

  # Defaulters list (overdue), highest balance first.
  def defaulters
    rows = scoped.where(status: 'overdue').order(Sequel.desc(:balance_paise)).all
    return_success(rows.map(&:as_pos))
  end

  # CSV export of the current (filtered) invoice set.
  def export_csv
    ds = scoped.order(Sequel.desc(:issued_on))
    ds = ds.where(status: qs[:status]) if qs[:status].present? && qs[:status] != 'all'
    headers = %w[Invoice Owner Property Plan Issued Due Amount LateFee Paid Balance Status]
    csv = CSV.generate do |out|
      out << headers
      ds.each do |i|
        out << [i.number, i.owner_name, i.property, i.plan_name, i.issued_on, i.due_date,
                (i.amount_paise || 0) / 100, (i.late_fee_paise || 0) / 100,
                (i.paid_paise || 0) / 100, (i.balance_paise || 0) / 100, i.status]
      end
    end
    r.response['Content-Type'] = 'text/csv'
    r.response['Content-Disposition'] = 'attachment; filename="invoices.csv"'
    csv
  end

  def item(id = rp[:id])
    @item ||= scoped[id] || return_errors!('Invoice not found', 404)
  end

  private

  def status_counts
    counts = scoped.group_and_count(:status).all
                   .each_with_object({}) { |row, h| h[row[:status]] = row[:count] }
    counts['all'] = scoped.count
    counts
  end

  # Grace days before a penalty applies — configurable in Settings (defaults 0).
  def penalty_grace_days
    (Client[current_client_id]&.settings || {})['penalty_grace_days'].to_i
  end

  # Monthly interest rate (%) on overdue balances — configurable in Settings
  # (defaults 0 = interest off).
  def interest_rate
    (Client[current_client_id]&.settings || {})['interest_percent_monthly'].to_f
  end

  def next_invoice_number
    year = Date.today.year
    seq = scoped.where(Sequel.like(:number, "INV-#{year}-%")).count + 1
    "INV-#{year}-#{format('%04d', seq)}"
  end

  def default_period(plan)
    %w[yearly].include?(plan.frequency) ? "FY #{Date.today.year}" : Date.today.strftime('%b %Y')
  end

  def parse_date(val)
    val.present? ? Date.parse(val.to_s) : nil
  rescue ArgumentError
    nil
  end

  def self.fields
    { save: %i[plot_id plan_id owner_name property property_type plan_name category
               period amount_paise late_fee_paise tax_paise due_date issued_on status] }
  end
end
