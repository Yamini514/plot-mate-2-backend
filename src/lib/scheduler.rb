# Background scheduler. There is no long-running job process in PlotMate, so this
# is a request-free dispatcher meant to be run periodically by an external cron
# (Render Cron Job, Windows Task Scheduler, or unix cron) via `rake scheduler:run`.
#
# It does the work the app previously only hinted at: actually sending the dues
# reminders that admins scheduled, nudging on documents about to expire, and
# reminding owners/vendors about due preventive-maintenance inspections. Every
# dispatch is idempotent — a "sent/reminded" stamp (migration 0056) stops it
# re-nagging on the next tick.
#
# Tenancy: this runs across ALL clients (it is not request-scoped), so every
# query carries its own client_id and every delivery resolves that client's own
# SMTP / WhatsApp config (App::Mailer / App::WhatsApp layer ENV <- client settings).
module App
  module Scheduler
    module_function

    # How soon (days) before a document expires we start reminding, and how often
    # (days) we re-remind for still-open document / maintenance items.
    EXPIRY_WINDOW_DAYS = 30
    RENAG_AFTER_DAYS   = 7

    # Run everything and return a summary hash the rake task prints.
    def run!(now: Time.now)
      {
        reminders:   dispatch_due_reminders(now: now),
        documents:   dispatch_document_expiry(now: now),
        maintenance: dispatch_maintenance_due(now: now),
        notices:     dispatch_scheduled_notices(now: now)
      }
    end

    # --- scheduled notices ---------------------------------------------------
    # Publish any scheduled announcement whose time has come (flips it live in
    # the in-app feed). Email/WhatsApp blasts stay an admin action.
    def dispatch_scheduled_notices(now: Time.now)
      return { considered: 0, published: 0 } unless App::Models::Announcement.db.table_exists?(:announcements) &&
                                                    App::Models::Announcement.columns.include?(:status)
      due = App::Models::Announcement.where(status: 'scheduled')
                                     .where { scheduled_at <= now }.all
      due.each { |a| a.update(status: 'published', published_at: now, updated_at: now) }
      { considered: due.size, published: due.size }
    rescue => e
      App.logger.warn("[Scheduler] scheduled notices: #{e.message}")
      { considered: 0, published: 0, error: e.message }
    end

    # --- billing reminders ---------------------------------------------------
    # Send every scheduled dues reminder whose time has come, then mark it sent.
    def dispatch_due_reminders(now: Time.now)
      cutoff = end_of_day(now)
      due = App::Models::Reminder
            .where(status: 'scheduled')
            .where(Sequel.|({ scheduled_for: nil }, (Sequel[:scheduled_for] <= cutoff)))
            .all

      sent = 0; failed = 0
      due.each do |r|
        client = client_cache(r.client_id)
        next unless client
        res = deliver_reminder(r, client)
        if res[:ok] && res[:sent]
          r.update(status: 'sent', sent_at: now, updated_at: now)
          sent += 1
        else
          failed += 1
          App.logger.warn("[Scheduler] reminder ##{r.id} not sent: #{res[:error] || 'no contact / unsupported channel'}")
        end
      end
      { considered: due.size, sent: sent, failed: failed }
    end

    def deliver_reminder(r, client)
      case r.channel
      when 'email'    then deliver_reminder_email(r, client)
      when 'whatsapp' then deliver_reminder_whatsapp(r, client)
      else { ok: true, sent: false, error: "channel '#{r.channel}' has no gateway" }
      end
    end

    def deliver_reminder_email(r, client)
      to = owner_email(r)
      return { ok: false, sent: false, error: 'no email on file' } if blank?(to)
      App::Mailer.deliver(
        to: to, subject: "Maintenance fee reminder — #{client.name}",
        html_body: reminder_html(r, client), client: client
      )
      { ok: true, sent: true, to: to }
    rescue => e
      { ok: false, sent: false, error: e.message }
    end

    def deliver_reminder_whatsapp(r, client)
      to = owner_phone(r)
      return { ok: false, sent: false, error: 'no phone on file' } if blank?(to)
      App::WhatsApp.send_reminder(
        to: to, owner_name: r.owner_name || 'Owner',
        amount: format_rupees(r.amount_paise), plot_no: r.plot_no,
        association: client.name, client: client
      )
      { ok: true, sent: true, to: to }
    rescue => e
      { ok: false, sent: false, error: e.message }
    end

    # --- document expiry -----------------------------------------------------
    # Email each client's admins a digest of documents expiring within the window
    # (or already expired) that we haven't reminded about recently.
    def dispatch_document_expiry(now: Time.now)
      cutoff      = (now.to_date + EXPIRY_WINDOW_DAYS)
      renag_floor = now - RENAG_AFTER_DAYS * 86_400
      reminded = 0; clients_notified = 0

      grouped = App::Models::Document
                .where(active: true).exclude(expiry_date: nil)
                .where { expiry_date <= cutoff }
                .where(Sequel.|({ expiry_reminded_at: nil }, (Sequel[:expiry_reminded_at] < renag_floor)))
                .all.group_by(&:client_id)

      grouped.each do |client_id, docs|
        client = client_cache(client_id)
        next unless client
        emails = admin_emails(client_id)
        next if emails.empty?
        begin
          App::Mailer.deliver(
            to: emails.join(', '),
            subject: "#{docs.size} document(s) expiring soon — #{client.name}",
            html_body: document_digest_html(docs, client), client: client
          )
          docs.each do |d|
            d.update(expiry_reminded_at: now, updated_at: now)
            # Notify the owning resident directly (Owner Portal) when it's their doc.
            if d.respond_to?(:owner_user_id) && d.owner_user_id
              App::Notify.create(user_id: d.owner_user_id, client_id: client_id, kind: 'document',
                                 title: 'Document expiring soon',
                                 body: "#{d.name} expires on #{d.expiry_date}. Please upload a renewed copy.",
                                 link: '/member/documents', entity: d)
            end
          end
          reminded += docs.size
          clients_notified += 1
        rescue => e
          App.logger.warn("[Scheduler] doc-expiry email failed for client #{client_id}: #{e.message}")
        end
      end
      { considered: grouped.values.sum(&:size), reminded: reminded, clients_notified: clients_notified }
    end

    # --- preventive maintenance ----------------------------------------------
    # Remind the assignee (or, failing that, the admins) about active schedules
    # that are due-soon or overdue and haven't been nudged recently.
    def dispatch_maintenance_due(now: Time.now)
      renag_floor = now - RENAG_AFTER_DAYS * 86_400
      schedules = App::Models::MaintenanceSchedule
                  .where(active: true).exclude(next_due_on: nil)
                  .where(Sequel.|({ reminded_at: nil }, (Sequel[:reminded_at] < renag_floor)))
                  .all
                  .select { |s| %w[overdue due_soon].include?(s.due_state) }

      sent = 0
      schedules.each do |s|
        client = client_cache(s.client_id)
        next unless client
        to = staff_email(s.client_id, s.assignee_staff_id)
        to = admin_emails(s.client_id).join(', ') if blank?(to)
        next if blank?(to)
        begin
          App::Mailer.deliver(
            to: to,
            subject: "Maintenance due: #{s.title} — #{client.name}",
            html_body: maintenance_html(s, client), client: client
          )
          s.update(reminded_at: now, updated_at: now)
          sent += 1
        rescue => e
          App.logger.warn("[Scheduler] maintenance email failed for schedule ##{s.id}: #{e.message}")
        end
      end
      { considered: schedules.size, sent: sent }
    end

    # --- lookups -------------------------------------------------------------

    def client_cache(id)
      (@client_cache ||= {})[id] ||= App::Models::Client[id]
    end

    def admin_emails(client_id)
      App::Models::User
        .where(client_id: client_id, role: 2, active: true)
        .exclude(email: nil).select_map(:email).reject { |e| blank?(e) }.uniq
    end

    def staff_email(client_id, staff_id)
      return nil unless staff_id
      App::Models::Staff.where(client_id: client_id, id: staff_id).get(:email)
    end

    def owner_email(r)
      return nil if blank?(r.plot_no)
      App::Models::Plot.where(client_id: r.client_id, plot_no: r.plot_no).get(:email)
    end

    def owner_phone(r)
      return nil if blank?(r.plot_no)
      App::Models::Plot.where(client_id: r.client_id, plot_no: r.plot_no).get(:phone)
    end

    # --- helpers -------------------------------------------------------------

    def blank?(v) = v.to_s.strip.empty?

    def end_of_day(t) = Time.new(t.year, t.month, t.day, 23, 59, 59, t.utc_offset)

    def format_rupees(paise)
      rupees = (paise.to_i / 100).to_s
      if rupees.length > 3
        head = rupees[0...-3].reverse.scan(/\d{1,2}/).join(',').reverse
        rupees = "#{head},#{rupees[-3..]}"
      end
      "₹#{rupees}"
    end

    def reminder_html(r, client)
      App::Mailer.branded_email(
        client: client, heading: 'Maintenance fee reminder',
        intro: "Dear #{r.owner_name || 'Owner'}, the maintenance fee of " \
               "<b>#{format_rupees(r.amount_paise)}</b> for plot <b>#{r.plot_no}</b> " \
               "at <b>#{client.name}</b> is currently pending.",
        outro: 'Please clear it at your earliest convenience. If you have already paid, kindly ignore this message.'
      )
    end

    def document_digest_html(docs, client)
      rows = docs.map do |d|
        state = d.respond_to?(:expiry_state) ? d.expiry_state : nil
        flag  = state == 'expired' ? ' (expired)' : ''
        "<li><b>#{d.name}</b> — #{d.category || d.doc_type || 'document'} · expires #{d.expiry_date}#{flag}</li>"
      end.join
      App::Mailer.branded_email(
        client: client, heading: 'Documents expiring soon',
        intro: "The following document(s) for <b>#{client.name}</b> are expiring within " \
               "#{EXPIRY_WINDOW_DAYS} days or have already expired:<br><ul>#{rows}</ul>",
        outro: 'Please renew them and upload the updated copies to the document vault.'
      )
    end

    def maintenance_html(s, client)
      App::Mailer.branded_email(
        client: client, heading: 'Preventive maintenance due',
        intro: "The schedule <b>#{s.title}</b> (#{s.area || s.category}) at " \
               "<b>#{client.name}</b> is <b>#{s.due_state == 'overdue' ? 'overdue' : 'due soon'}</b> " \
               "(due #{s.next_due_on}).",
        outro: 'Please carry out the inspection and log the completion in PlotMate.'
      )
    end
  end
end
