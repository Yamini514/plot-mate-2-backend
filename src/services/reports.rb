class App::Services::Reports < App::Services::Base
  # Cross-module rollup for the reports dashboard.
  def overview
    cid = current_client_id
    inv = Invoice.where(client_id: cid).exclude(status: 'cancelled').all
    billed    = inv.sum(&:total_paise)
    collected = inv.sum { |i| i.paid_paise || 0 }
    credits = Transaction.where(client_id: cid, direction: 'credit').sum(:amount_paise) || 0
    debits  = Transaction.where(client_id: cid, direction: 'debit').sum(:amount_paise) || 0

    return_success(
      collection: {
        billed: billed / 100, collected: collected / 100,
        outstanding: (billed - collected) / 100,
        rate: billed.zero? ? 0 : (collected * 1000 / billed) / 10.0
      },
      treasury: { income: credits / 100, expense: debits / 100, balance: (credits - debits) / 100 },
      expenses_by_category: Expense.where(client_id: cid).all.group_by(&:category)
                                   .map { |c, l| { name: c, value: l.sum { |e| e.amount_paise } / 100 } },
      collection_trend: collection_trend(inv),
      outstanding_aging: outstanding_aging(inv),
      recent_activity: recent_activity(cid),
      plots:      { total: Plot.where(client_id: cid).count,
                    paid: Plot.where(client_id: cid, payment_status: 'paid').count },
      complaints_open: Complaint.where(client_id: cid, status: 'open').count,
      tickets_open:    Ticket.where(client_id: cid).where(status: Ticket::OPEN_STATUSES).count,
      defaulters:      inv.count { |i| i.status == 'overdue' }
    )
  end

  private

  # Billed vs collected per issue-month (real data; sparse until more history).
  def collection_trend(invoices)
    by_month = Hash.new { |h, k| h[k] = { billed: 0, collected: 0 } }
    invoices.each do |i|
      next unless i.issued_on
      key = i.issued_on.strftime('%b %Y')
      by_month[key][:billed] += i.total_paise
      by_month[key][:collected] += (i.paid_paise || 0)
    end
    by_month.sort_by { |m, _| Date.parse("1 #{m}") rescue Date.today }
            .map { |m, v| { month: m, billed: v[:billed] / 100, collected: v[:collected] / 100 } }
  end

  # Overdue balances bucketed by age.
  def outstanding_aging(invoices)
    today = Date.today
    buckets = { '0–15 days' => 0, '16–30 days' => 0, '31–60 days' => 0, '60+ days' => 0 }
    invoices.select { |i| i.status == 'overdue' && i.due_date }.each do |i|
      d = (today - i.due_date).to_i
      key = d <= 15 ? '0–15 days' : d <= 30 ? '16–30 days' : d <= 60 ? '31–60 days' : '60+ days'
      buckets[key] += (i.balance_paise || 0)
    end
    buckets.map { |name, value| { name: name, value: value / 100 } }
  end

  # Latest cross-module events for the dashboard feed.
  def recent_activity(cid)
    acts = []
    Payment.where(client_id: cid).order(Sequel.desc(:created_at)).limit(4).each do |p|
      acts << { type: 'payment', text: "#{p.owner_name} (#{p.property}) paid #{format_currency(p.amount_paise)}", at: p.created_at }
    end
    Complaint.where(client_id: cid).order(Sequel.desc(:created_at)).limit(3).each do |c|
      acts << { type: 'complaint', text: "New complaint: #{c.title} (#{c.plot_no})", at: c.created_at }
    end
    Expense.where(client_id: cid).order(Sequel.desc(:created_at)).limit(2).each do |e|
      acts << { type: 'expense', text: "#{format_currency(e.amount_paise)} expense — #{e.description}", at: e.created_at }
    end
    acts.sort_by { |a| a[:at] || Time.at(0) }.reverse.first(8)
         .map { |a| { type: a[:type], text: a[:text], at: a[:at] } }
  end
end
