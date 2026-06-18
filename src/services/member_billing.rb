class App::Services::MemberBilling < App::Services::Base
  # The plot this member owns (linked via their profile's plot_no).
  def my_plot
    @my_plot ||= begin
      pno = App.cu.user_obj.extras&.dig('plot_no')
      Plot[client_id: current_client_id, plot_no: pno] if pno.present?
    end
  end

  def my_invoices_ds
    base = Invoice.where(client_id: current_client_id)
    conds = [Sequel.expr(owner_name: App.cu.user_obj.full_name)]
    conds << Sequel.expr(plot_id: my_plot.id) if my_plot
    conds << Sequel.expr(property: my_plot_no) if my_plot_no.present?
    base.where(Sequel.|(*conds))
  end

  # The plot(s) this member owns (by linked plot_no, else by owner name).
  def my_plots
    ds = Plot.where(client_id: current_client_id, active: true)
    rows = my_plot_no.present? ? ds.where(plot_no: my_plot_no).all
                               : ds.where(owner_name: App.cu.user_obj.full_name).all
    return_success(rows.map(&:as_pos))
  end

  # This member's payment receipts.
  def my_payments
    ds = Payment.where(client_id: current_client_id)
    ds = my_plot ? ds.where(plot_id: my_plot.id) : ds.where(owner_name: App.cu.user_obj.full_name)
    return_success(ds.order(Sequel.desc(:paid_on), Sequel.desc(:id)).all.map(&:as_pos))
  end

  # Community treasury (read-only transparency view).
  def treasury
    cid = current_client_id
    credits = Transaction.where(client_id: cid, direction: 'credit').sum(:amount_paise) || 0
    debits  = Transaction.where(client_id: cid, direction: 'debit').sum(:amount_paise) || 0
    recent  = Transaction.where(client_id: cid).order(Sequel.desc(:occurred_on), Sequel.desc(:id))
                         .limit(20).all.map(&:as_pos)
    return_success(
      summary: { income: credits / 100, expense: debits / 100, balance: (credits - debits) / 100 },
      transactions: recent
    )
  end

  # Visitors to this member's plot.
  def my_visitors
    ds = Visitor.where(client_id: current_client_id)
    ds = ds.where(plot_no: my_plot_no) if my_plot_no.present?
    return_success(ds.order(Sequel.desc(:created_at)).limit(50).all.map(&:as_pos))
  end

  # Member pre-approves an expected visitor and gets a gate pass.
  def preapprove_visitor
    obj = Visitor.new(
      client_id: current_client_id,
      name: params[:name], phone: params[:phone],
      resident_name: App.cu.user_obj.full_name, plot_no: my_plot_no,
      purpose: params[:purpose], vehicle_no: params[:vehicle_no],
      expected_on: parse_date(params[:expected_on]),
      status: 'approved',
      code: "VIS-#{2400 + Visitor.where(client_id: current_client_id).count + 1}",
      pass_code: Visitor.gen_pass_code
    )
    save(obj) { |v| return_success(v.as_pos) }
  end

  # Member approves / rejects a guard-registered visitor to their plot.
  def approve_visitor
    v = my_visitor
    v.status = 'approved'
    v.pass_code ||= Visitor.gen_pass_code
    save(v) { return_success(v.as_pos) }
  end

  def reject_visitor
    v = my_visitor
    v.status = 'rejected'
    save(v) { return_success(v.as_pos) }
  end

  # --- helpers (not routed) ---
  def my_plot_no
    App.cu.user_obj.extras&.dig('plot_no')
  end

  def my_visitor
    Visitor[client_id: current_client_id, id: rp[:id]] || return_errors!('Visitor not found', 404)
  end

  def parse_date(val)
    val.present? ? Date.parse(val.to_s) : nil
  rescue ArgumentError
    nil
  end

  def overview
    invs     = my_invoices_ds.order(Sequel.desc(:due_date)).all
    history  = invs.select { |i| (i.paid_paise || 0).positive? || i.status == 'paid' }
    upcoming = invs.select { |i| Invoice::OPEN_STATUSES.include?(i.status) && i.balance_paise.to_i.positive? }

    return_success(
      summary: {
        total_due:      upcoming.sum { |i| i.balance_paise || 0 } / 100,
        next_due:       upcoming.map(&:due_date).compact.min,
        paid_this_year: invs.select { |i| i.issued_on&.year == Date.today.year }
                            .sum { |i| i.paid_paise || 0 } / 100,
        autopay:        !!App.cu.user_obj.extras&.dig('autopay')
      },
      upcoming: upcoming.map(&:as_pos),
      history:  history.map(&:as_pos)
    )
  end

  # Member pays an invoice (manual confirmation; Stripe path uses StripeBilling).
  def pay
    inv = my_invoices_ds.where(id: params[:invoice_id]).first ||
          return_errors!('Invoice not found', 404)
    amount_paise = params[:amount].present? ? (params[:amount].to_f * 100).round : inv.balance_paise.to_i
    return_errors!('Nothing due', 400) if amount_paise <= 0

    pmt = Payment.record!(invoice: inv, amount_paise: amount_paise,
                          mode: params[:mode].presence || 'upi',
                          reference: params[:reference], provider: 'manual')
    return_success(pmt.as_receipt)
  rescue => e
    App.logger.error("Member pay error: #{e.message}")
    return_errors!("Payment failed: #{e.message}", 400)
  end
end
