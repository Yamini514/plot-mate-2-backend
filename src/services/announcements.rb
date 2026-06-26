require 'time' # Time.parse for scheduled_at

class App::Services::Announcements < App::Services::Base
  def model = Announcement

  def list
    ds = scoped.order(Sequel.desc(:pinned), Sequel.desc(:date), Sequel.desc(:id))
    ds = ds.where(type: qs[:type]) if qs[:type].present? && qs[:type] != 'all'
    # Members only see published notices; admins see drafts/scheduled too.
    ds = ds.exclude(status: %w[scheduled draft]) unless App.cu.user_obj&.admin?
    rows = ds.all
    # Cheap engagement counts for the whole page (two grouped queries, no N+1).
    acks = AnnouncementAck.where(announcement_id: rows.map(&:id))
                          .group_and_count(:announcement_id).all
                          .to_h { |r| [r[:announcement_id], r[:count]] }
    cmts = AnnouncementComment.where(announcement_id: rows.map(&:id), status: 'approved')
                              .group_and_count(:announcement_id).all
                              .to_h { |r| [r[:announcement_id], r[:count]] }
    return_success(rows.map { |a| a.as_pos.merge(ack_count: acks[a.id] || 0, comment_count: cmts[a.id] || 0) })
  end

  def get
    a = item
    return_success(a.as_pos.merge(
      acks:      AnnouncementAck.where(announcement_id: a.id).order(Sequel.desc(:acked_at)).all.map(&:as_pos),
      comments:  comments_for(a),
      reactions: reaction_summary(a.id)
    ))
  end

  def create
    obj = model.new(data_for(:save))
    obj.client_id = current_client_id
    obj.code ||= "AN-#{scoped.count + 1}"
    obj.author ||= App.cu.user_obj.full_name
    obj.date ||= Date.today
    # Scheduled publishing: a future scheduled_at holds the notice until the
    # scheduler reaches it (no delivery now). Otherwise publish + deliver.
    sched = parse_time(params[:scheduled_at])
    if sched && sched > Time.now
      obj.set(scheduled_at: sched, status: 'scheduled')
      save(obj) { |a| return_success(a.as_pos.merge(delivery: { scheduled: true })) }
    else
      obj.status = 'published'
      obj.published_at ||= Time.now
      save(obj) do |a|
        delivery = deliver(a)
        return_success(a.as_pos.merge(delivery: delivery))
      end
    end
  end

  # Publish a scheduled notice now (used by App::Scheduler when due, or manually).
  def publish_now(a = item)
    a.set(status: 'published', published_at: Time.now)
    a.save_changes
    deliver(a)
  end

  def parse_time(v)
    v.present? ? Time.parse(v.to_s) : nil
  rescue ArgumentError
    nil
  end

  def update
    data = data_for(:save)
    item.set_fields(data, data.keys)
    save(item) { |a| return_success(a.as_pos) }
  end

  def pin
    item.pinned = !item.pinned
    save(item) { |a| return_success(a.as_pos) }
  end

  # --- engagement ------------------------------------------------------------
  # Member acknowledges they've read the notice (idempotent per user).
  def ack
    a = item
    u = App.cu.user_obj
    existing = AnnouncementAck.where(announcement_id: a.id, user_id: u.id).first
    unless existing
      AnnouncementAck.create(client_id: a.client_id, announcement_id: a.id, user_id: u.id,
                             plot_no: u.extras&.dig('plot_no'), name: u.full_name, acked_at: Time.now)
    end
    return_success(acked: true, ack_count: AnnouncementAck.where(announcement_id: a.id).count)
  end

  def comment
    a = item
    return_errors!('Comments are closed on this notice', 422) unless a.allow_comments
    # Admins post pre-approved; member comments can be auto-approved or moderated.
    status = App.cu.user_obj&.admin? ? 'approved' : (moderated? ? 'pending' : 'approved')
    c = AnnouncementComment.new(client_id: a.client_id, announcement_id: a.id,
                                author_id: App.cu.id, author_name: App.cu.user_obj&.full_name,
                                body: params[:body], status: status)
    save(c) { return_success(c.as_pos) }
  end

  def moderate_comment
    c = AnnouncementComment.where(client_id: current_client_id, id: rp[:comment]).first ||
        return_errors!('Comment not found', 404)
    status = params[:status].to_s
    return_errors!('Invalid status', 422) unless AnnouncementComment::STATUSES.include?(status)
    c.update(status: status)
    return_success(c.as_pos)
  end

  # Toggle the caller's reaction (re-reacting with the same kind removes it).
  def react
    a = item
    kind = params[:kind].presence || 'like'
    existing = AnnouncementReaction.where(announcement_id: a.id, user_id: App.cu.id).first
    if existing && existing.kind == kind
      existing.delete
    elsif existing
      existing.update(kind: kind)
    else
      AnnouncementReaction.create(client_id: a.client_id, announcement_id: a.id,
                                  user_id: App.cu.id, kind: kind)
    end
    return_success(reactions: reaction_summary(a.id))
  end

  def item(id = rp[:id]) = (@item ||= scoped[id] || return_errors!('Announcement not found', 404))

  def self.fields
    { save: %i[title body type pinned author date audience_type audience_values
               attachment_url attachment_name channels allow_comments] }
  end

  private

  def moderated? = ((Client[current_client_id]&.settings || {})['moderate_comments'] == true)

  def comments_for(a)
    ds = AnnouncementComment.where(announcement_id: a.id).order(:created_at)
    ds = ds.where(status: 'approved') unless App.cu.user_obj&.admin?
    ds.all.map(&:as_pos)
  end

  def reaction_summary(aid)
    AnnouncementReaction.where(announcement_id: aid).group_and_count(:kind).all
                        .to_h { |r| [r[:kind] || 'like', r[:count]] }
  end

  # Resolve the targeted plots for this notice, by audience type.
  def target_plots(a)
    base = Plot.where(client_id: a.client_id, active: true)
    vals = a.audience_values || []
    case a.audience_type
    when 'phase'  then base.where(phase: vals).all
    when 'owners' then base.where(plot_no: vals).all
    when 'block'  then base.where(phase: vals).all  # 'block' aliases phase grouping for now
    else base.all
    end
  end

  # Best-effort multi-channel delivery (capped). in_app needs no send — it's the
  # default listing. Never raises; returns a per-channel summary.
  def deliver(a)
    channels = a.channels || []
    return { in_app: true } if (channels - ['in_app']).empty?

    plots  = target_plots(a).first(200)
    client = Client[current_client_id]
    sent = { email: 0, whatsapp: 0, failed: 0 }
    plots.each do |p|
      begin
        if channels.include?('email') && p.email.to_s.strip != ''
          App::Mailer.deliver(to: p.email, subject: a.title,
                              html_body: notice_html(a, client), client: client)
          sent[:email] += 1
        end
        if channels.include?('whatsapp') && p.phone.to_s.strip != '' &&
           App::WhatsApp.respond_to?(:send_announcement)
          App::WhatsApp.send_announcement(to: p.phone, title: a.title, body: a.body.to_s,
                                          association: client&.name, client: client)
          sent[:whatsapp] += 1
        end
      rescue => e
        sent[:failed] += 1
        App.logger.error("notice delivery failed for #{p.plot_no}: #{e.message}")
      end
    end
    sent.merge(in_app: channels.include?('in_app'), recipients: plots.length)
  end

  def notice_html(a, client)
    "<div style=\"font-family:system-ui,Arial,sans-serif;color:#0f172a;line-height:1.6\">" \
      "<h2 style=\"margin:0 0 8px\">#{a.title}</h2>" \
      "<p>#{a.body.to_s.gsub("\n", '<br>')}</p>" \
      "#{a.attachment_url ? "<p><a href=\"#{a.attachment_url}\">#{a.attachment_name || 'Attachment'}</a></p>" : ''}" \
      "<p style=\"color:#94a3b8;font-size:12px;margin-top:16px\">#{client&.name} · via PlotMate</p>" \
    "</div>"
  end
end
