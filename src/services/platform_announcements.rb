class App::Services::PlatformAnnouncements < App::Services::Base
  # Global Notification Center — platform announcements broadcast to ventures.
  # Not tenant-scoped (super-admin only). Lifecycle: draft → scheduled → published.
  def model = PlatformAnnouncement

  SORTABLE = { 'title' => :title, 'priority' => :priority, 'status' => :status,
               'start_at' => :start_at, 'created_at' => :created_at }.freeze

  def list
    ds = PlatformAnnouncement.dataset
    ds = ds.where(status: qs[:status])     if qs[:status].present? && qs[:status] != 'all'
    ds = ds.where(priority: qs[:priority]) if qs[:priority].present?
    if qs[:search].present?
      term = "%#{qs[:search]}%"
      ds = ds.where { Sequel.ilike(:title, term) | Sequel.ilike(:message, term) }
    end
    ds    = apply_sort(ds, SORTABLE)
    total = ds.count
    return_success(ds.offset(offset).limit(limit).all.map(&:as_pos),
                   counts: counts_by_status, **pagination_meta(total))
  end

  def get = return_success(item.as_pos)

  def create
    obj = PlatformAnnouncement.new(announcement_attrs)
    validate_announcement!(obj)
    obj.code   ||= "ANN-#{1001 + PlatformAnnouncement.count}"
    obj.status ||= 'draft'
    obj.created_by = App.cu.id
    save(obj) do
      App::Audit.record('announcement.create', entity: obj,
                        summary: "Created announcement #{obj.title}", meta: { status: obj.status })
      return_success(obj.as_pos)
    end
  end

  def update
    item.set(announcement_attrs)
    validate_announcement!(item)
    item.updated_by = App.cu.id
    save(item) { return_success(item.as_pos) }
  end

  # Send it live now. A future start_at means it's effectively scheduled, but
  # publishing makes it visible to its audience.
  def publish
    item.set(status: 'published', published_at: Time.now, updated_by: App.cu.id)
    save(item) do
      App::Audit.record('announcement.publish', entity: item,
                        summary: "Published announcement #{item.title}",
                        meta: { audience: item.audience, client_ids: item.client_ids })
      return_success(item.as_pos)
    end
  end

  def delete
    title = item.title
    item.destroy
    App::Audit.record('announcement.delete', entity_type: 'PlatformAnnouncement',
                      summary: "Deleted announcement #{title}")
    return_success(deleted: true)
  end

  def item(id = rp[:id])
    @item ||= (PlatformAnnouncement[id] || return_errors!('Announcement not found', 404))
  end

  private

  # Map the posted payload onto the model's columns (no mass-assignment of
  # status/published_at — those move only through create defaults / publish).
  def announcement_attrs
    attrs = {
      title:    params[:title],
      message:  params[:message],
      priority: params[:priority].presence || 'normal',
      audience: params[:audience].presence || 'all',
      start_at: params[:start_at].presence,
      end_at:   params[:end_at].presence
    }
    attrs[:status]     = params[:status] if PlatformAnnouncement::STATUSES.include?(params[:status].to_s)
    attrs[:client_ids] = Array(params[:client_ids]).map(&:to_i) if params[:audience] == 'selected'
    attrs[:client_ids] = [] if params[:audience] == 'all'
    attrs.compact
  end

  def validate_announcement!(obj)
    checks = {
      'title'   => App::Validate.text(obj.title, max: 160),
      'message' => App::Validate.presence(obj.message, label: 'Message'),
      'end_at'  => App::Validate.date_range(obj.start_at, obj.end_at)
    }
    if obj.audience == 'selected' && Array(obj.client_ids).empty?
      checks['client_ids'] = 'Select at least one venture'
    end
    validate!(checks)
  end

  def counts_by_status
    c = PlatformAnnouncement.group_and_count(:status).all
                            .each_with_object({}) { |r, h| h[r[:status]] = r[:count] }
    c['all'] = PlatformAnnouncement.count
    c
  end

  def self.fields
    { save: %i[title message priority audience client_ids start_at end_at status] }
  end
end
