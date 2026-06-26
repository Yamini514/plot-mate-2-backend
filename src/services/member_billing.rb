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

  # Search the plot registry so an owner can find the plot they want to claim.
  def plot_search
    q = qs[:q].to_s.strip
    return return_success([]) if q.empty?
    rows = Plot.where(client_id: current_client_id, active: true)
               .where(Sequel.ilike(:plot_no, "%#{q}%"))
               .order(Sequel.asc(:plot_no)).limit(20).all
    return_success(rows.map { |p|
      { id: p.id, plot_no: p.plot_no, owner_name: p.owner_name,
        status: p.status, membership: p.membership }
    })
  end

  # Owner submits proof of ownership for a plot → opens a plot_claim approval
  # request for the admin/association to review. The approve side-effect links
  # the plot to this owner (see Approvals#claim_plot!).
  def claim_plot
    plot = Plot.where(client_id: current_client_id, id: params[:plot_id].to_i).first ||
           return_errors!('Plot not found', 404)
    u = App.cu.user_obj
    dup = ApprovalRequest
          .where(client_id: current_client_id, request_type: 'plot_claim',
                 submitted_by: u.id, status: ApprovalRequest::OPEN_STATUSES).all
          .any? { |r| (r.payload || {})['plot_id'] == plot.id }
    return_errors!('You already have a pending claim for this plot', 422) if dup

    req = ApprovalRequest.open!(
      client_id: current_client_id, request_type: 'plot_claim',
      subject_type: 'Plot', subject_id: plot.id,
      payload: { 'plot_id' => plot.id, 'plot_no' => plot.plot_no, 'user_id' => u.id,
                 'proof_url' => params[:proof_url], 'proof_name' => params[:proof_name] },
      submitted_by: u.id, submitted_by_name: u.full_name
    )
    App::Audit.record('plot.claim.submit', entity: req, client_id: current_client_id,
                      summary: "#{u.full_name} submitted a claim for plot #{plot.plot_no}")
    return_success(req.as_pos)
  end

  # Ownership history + current co-owners for a plot the member owns.
  def plot_history
    plot = Plot.where(client_id: current_client_id, id: rp[:id]).first || return_errors!('Plot not found', 404)
    u = App.cu.user_obj
    owns = (my_plot_no.present? && plot.plot_no == my_plot_no) ||
           (plot.owner_name.present? && plot.owner_name == u.full_name)
    return_errors!('Not your plot', 403) unless owns
    transfers = App::Models::Transfer.where(client_id: current_client_id, plot_id: plot.id).order(:created_at).all
    owners = App::Models.const_defined?(:PlotOwner) ?
             App::Models::PlotOwner.where(client_id: current_client_id, plot_id: plot.id).order(Sequel.desc(:primary_owner)).all.map(&:as_pos) : []
    return_success(
      owners: owners,
      transfers: transfers.map { |t| { code: t.code, from: t.from_owner_name, to: t.to_owner_name,
                                       reason: t.reason, status: t.status, at: t.created_at } }
    )
  rescue StandardError => e
    App.logger.error("plot_history: #{e.message}")
    return_success(owners: [], transfers: [])
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

  # Defensive dashboard counters (tables may vary by migration state).
  def project_count(cid)
    return 0 unless App::Models.const_defined?(:Project)
    App::Models::Project.where(client_id: cid, active: true).exclude(status: 'completed').count
  rescue StandardError
    0
  end

  def expiring_doc_count(cid, uid)
    cutoff = Date.today + 30
    App::Models::Document.where(client_id: cid, owner_user_id: uid, active: true)
                         .exclude(expiry_date: nil).where { expiry_date <= cutoff }.count
  rescue StandardError
    0
  end

  def notif_count(uid)
    return 0 unless App::Models.const_defined?(:Notification)
    App::Models::Notification.where(user_id: uid, read_at: nil).count
  rescue StandardError
    0
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
      history:  history.map(&:as_pos),
      alerts:   dashboard_alerts
    )
  end

  # Cross-module counts for the owner dashboard (all self-scoped + aggregate).
  def dashboard_alerts
    cid = current_client_id
    uid = App.cu.id
    {
      active_complaints: Complaint.where(client_id: cid, raised_by_user_id: uid,
                                         status: %w[open in_progress]).count,
      active_projects:   project_count(cid),
      pending_requests:  ApprovalRequest.where(client_id: cid, submitted_by: uid,
                                               status: ApprovalRequest::OPEN_STATUSES).count,
      expiring_documents: expiring_doc_count(cid, uid),
      unread_notifications: notif_count(uid)
    }
  end

  # Member reports an offline payment (UPI/bank/cash). It is created as PENDING
  # and does NOT touch the invoice balance or treasury until an admin verifies
  # it. The online (Stripe) path stays auto-verified via StripeBilling.
  def pay
    inv = my_invoices_ds.where(id: params[:invoice_id]).first ||
          return_errors!('Invoice not found', 404)
    amount_paise = params[:amount].present? ? (params[:amount].to_f * 100).round : inv.balance_paise.to_i
    return_errors!('Nothing due', 400) if amount_paise <= 0
    return_errors!('Amount exceeds balance', 400) if amount_paise > inv.balance_paise.to_i

    pmt = Payment.submit!(invoice: inv, amount_paise: amount_paise,
                          mode: params[:mode].presence || 'upi',
                          reference: params[:reference],
                          proof_url: params[:proof_url].presence,
                          proof_key: params[:proof_key].presence,
                          submitted_by_user_id: App.cu.id)
    App::Audit.record('payment.submit', entity: pmt, client_id: pmt.client_id,
                      summary: "#{App.cu.user_obj.full_name} reported a payment for #{inv.number} (awaiting verification)")
    return_success(pmt.as_pos.merge(message: 'Payment submitted — awaiting verification by the association.'))
  rescue => e
    App.logger.error("Member pay error: #{e.message}")
    return_errors!("Payment failed: #{e.message}", 400)
  end
end
