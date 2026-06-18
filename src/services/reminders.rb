class App::Services::Reminders < App::Services::Base
  def model = Reminder

  def list
    ds = scoped.order(Sequel.desc(:scheduled_for), Sequel.desc(:id))
    ds = ds.where(status: qs[:status]) if qs[:status].present? && qs[:status] != 'all'
    return_success(ds.all.map(&:as_pos))
  end

  def create
    d = data_for(:save)
    d['amount_paise'] = (d.delete('amount').to_f * 100).round if d.key?('amount')
    obj = model.new(d)
    obj.client_id = current_client_id
    obj.code ||= "RM-#{scoped.count + 1}"
    obj.status ||= 'scheduled'
    save(obj) do |r|
      # If this is an email reminder being sent now, actually deliver it.
      delivery = deliver_reminder(r)
      return_success(r.as_pos.merge(delivery: delivery))
    end
  end

  # Mark a reminder dispatched and (for email) actually send it.
  def send_now
    item.status = 'sent'
    save(item) do
      delivery = deliver_reminder(item)
      return_success(item.as_pos.merge(delivery: delivery))
    end
  end

  def item(id = rp[:id]) = (@item ||= scoped[id] || return_errors!('Reminder not found', 404))

  def self.fields
    { save: %i[plot_id plot_no owner_name amount channel scheduled_for status] }
  end

  private

  # Send the reminder over its channel. Email is wired to the owner's inbox via
  # the association's SMTP; SMS/WhatsApp are recorded for now (no gateway yet).
  # Never raises — returns a delivery summary the UI can surface.
  def deliver_reminder(r)
    return { ok: true, channel: r.channel, recorded: true } unless r.channel == 'email'
    return { ok: true, channel: 'email', recorded: true, sent: false } unless r.status == 'sent'

    to = params[:email].presence || owner_email(r)
    return { ok: false, channel: 'email', error: 'No email address on file for this owner.' } if to.to_s.strip.empty?

    client = Client[current_client_id]
    App::Mailer.deliver(
      to: to.to_s.strip,
      subject: "Maintenance fee reminder — #{client.name}",
      html_body: reminder_html(r, client),
      client: client
    )
    { ok: true, channel: 'email', sent: true, to: to }
  rescue => e
    App.logger.error("Reminder email failed: #{e.class}: #{e.message}")
    { ok: false, channel: 'email', error: e.message }
  end

  # The owner's email — from the linked plot's registry record.
  def owner_email(r)
    return nil if r.plot_no.to_s.empty?
    Plot.where(client_id: current_client_id, plot_no: r.plot_no).first&.email
  end

  def reminder_html(r, client)
    s    = client.settings || {}
    bank = s['bank'] || {}
    amt  = format_rupees(r.amount_paise)
    fy   = s['fy']
    pay_lines = []
    pay_lines << "UPI: <b>#{bank['upi']}</b>" if bank['upi'].to_s != ''
    if bank['account_no'].to_s != ''
      pay_lines << "Bank: #{bank['account_name']} · A/C #{bank['account_no']}" \
                   "#{bank['ifsc'].to_s.empty? ? '' : " · IFSC #{bank['ifsc']}"}"
    end
    pay_html = pay_lines.empty? ? '' :
      "<p style=\"margin:12px 0;padding:10px 12px;background:#f1f5f9;border-radius:8px;font-size:14px\">" \
      "<b>How to pay</b><br>#{pay_lines.join('<br>')}</p>"

    "<div style=\"font-family:system-ui,Segoe UI,Arial,sans-serif;color:#0f172a;font-size:15px;line-height:1.6\">" \
      "<p>Dear #{r.owner_name || 'Owner'},</p>" \
      "<p>This is a reminder that the maintenance fee of <b>#{amt}</b> for plot " \
      "<b>#{r.plot_no}</b> at <b>#{client.name}</b>#{fy ? " (FY #{fy})" : ''} is currently pending.</p>" \
      "#{pay_html}" \
      "<p>Please clear it at your earliest convenience. If you have already paid, kindly ignore this message.</p>" \
      "<p style=\"margin-top:16px\">Thank you,<br>#{client.name}</p>" \
      "<p style=\"color:#94a3b8;font-size:12px;margin-top:16px\">Sent from PlotMate</p>" \
    "</div>"
  end

  # ₹ with Indian-style grouping, from a paise integer.
  def format_rupees(paise)
    rupees = (paise.to_i / 100).to_s
    # group: last 3 digits, then pairs (Indian numbering)
    if rupees.length > 3
      head = rupees[0...-3]
      tail = rupees[-3..]
      head = head.reverse.scan(/\d{1,2}/).join(',').reverse
      rupees = "#{head},#{tail}"
    end
    "₹#{rupees}"
  end
end
