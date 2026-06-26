class App::Services::Projects < App::Services::Base
  # Capital / improvement project tracking. Tenant-scoped. Progress, spend and
  # delay flags accrue through project updates; progress photos reuse the
  # polymorphic Photo store.
  def model = Project

  def list
    ds = scoped.order(Sequel.desc(:created_at))
    ds = ds.where(status: qs[:status]) if qs[:status].present? && qs[:status] != 'all'
    return_success(ds.all.map { |p| p.as_pos }, counts: counts_by_status)
  end

  def get
    p = item
    return_success(detail_payload(p))
  end

  # --- member-facing (read + discuss) --------------------------------------
  def member_list
    rows = scoped.order(Sequel.desc(:created_at)).all
    return_success(rows.map { |p| p.as_pos })
  end

  def member_get
    p = item
    return_success(detail_payload(p, member: true))
  end

  def create
    p = Project.new(coerced)
    p.client_id = current_client_id
    p.code ||= "PRJ-#{1001 + scoped.count}"
    p.status ||= 'planned'
    set_vendor(p)
    save(p) { |row| return_success(row.as_pos) }
  end

  def update
    item.set_fields(coerced, coerced.keys)
    set_vendor(item)
    save(item) { |row| return_success(row.as_pos) }
  end

  # Post a progress update — advances percent, accrues spend, and flags delays.
  def add_update
    p = item
    percent = params[:percent].nil? ? nil : params[:percent].to_i.clamp(0, 100)
    spent   = params[:spent].nil? ? 0 : (params[:spent].to_f * 100).round
    is_delay = !!params[:is_delay]

    u = App::Models::ProjectUpdate.new(
      client_id: current_client_id, project_id: p.id, title: params[:title],
      note: params[:note], percent: percent, spent_paise: spent, is_delay: is_delay,
      author_name: App.cu.user_obj&.full_name
    )
    ok = App.db.transaction do
      raise Sequel::Rollback unless u.save
      p.progress_percent = percent if percent
      p.spent_paise = (p.spent_paise || 0) + spent if spent.positive?
      p.status = 'delayed' if is_delay && p.open?
      p.status = 'active'  if p.status == 'planned' && percent.to_i.positive?
      p.save_changes
      true
    end
    return_errors!('Could not post the update', 422) unless ok
    return_success(p.as_pos(with_updates: true))
  end

  def attach_photo
    return_errors!('A photo URL is required', 422) if params[:url].to_s.empty?
    photo = App::Models::Photo.new(
      client_id: current_client_id, url: params[:url], caption: params[:caption],
      kind: 'progress', category: 'project', attachable_type: 'Project',
      attachable_id: item.id, date: Date.today
    )
    photo.code ||= "PPH-#{App::Models::Photo.where(client_id: current_client_id).count + 1}"
    save(photo) { return_success(item.as_pos(with_updates: true).merge(photos: project_photos(item))) }
  end

  def complete
    item.set(status: 'completed', progress_percent: 100, completed_on: Date.today)
    save(item) do
      App::Audit.record('project.complete', entity: item, client_id: current_client_id,
                        summary: "Completed project #{item.code} — #{item.name}")
      return_success(item.as_pos)
    end
  end

  # --- milestones ----------------------------------------------------------
  def add_milestone
    p = item
    m = App::Models::ProjectMilestone.new(
      client_id: current_client_id, project_id: p.id, title: params[:title],
      due_on: parse_date(params[:due_on]), status: 'pending',
      sort_order: params[:sort_order].to_i
    )
    save(m) { return_success(detail_payload(p)) }
  end

  def toggle_milestone
    m = milestone
    done = m.status != 'done'
    m.set(status: done ? 'done' : 'pending', done_on: done ? Date.today : nil)
    save(m) { return_success(detail_payload(item)) }
  end

  def delete_milestone
    milestone.destroy
    return_success(detail_payload(item))
  end

  # --- discussion (comments + reactions) -----------------------------------
  def comment
    p = item
    status = App.cu.user_obj&.admin? ? 'approved' : (moderated? ? 'pending' : 'approved')
    c = App::Models::ProjectComment.new(
      client_id: current_client_id, project_id: p.id, author_id: App.cu.id,
      author_name: App.cu.user_obj&.full_name, body: params[:body], status: status
    )
    save(c) { return_success(c.as_pos) }
  end

  def moderate_comment
    c = App::Models::ProjectComment.where(client_id: current_client_id, id: rp[:comment]).first ||
        return_errors!('Comment not found', 404)
    return_errors!('Invalid status', 422) unless App::Models::ProjectComment::STATUSES.include?(params[:status].to_s)
    c.update(status: params[:status])
    return_success(c.as_pos)
  end

  def react
    p = item
    kind = params[:kind].presence || 'like'
    existing = App::Models::ProjectReaction.where(project_id: p.id, user_id: App.cu.id).first
    if existing && existing.kind == kind
      existing.delete
    elsif existing
      existing.update(kind: kind)
    else
      App::Models::ProjectReaction.create(client_id: current_client_id, project_id: p.id,
                                          user_id: App.cu.id, kind: kind)
    end
    return_success(reactions: reaction_summary(p.id))
  end

  def item(id = rp[:id]) = (@item ||= scoped[id] || return_errors!('Project not found', 404))

  private

  def milestone
    App::Models::ProjectMilestone
      .where(client_id: current_client_id, project_id: item.id, id: rp[:milestone]).first ||
      return_errors!('Milestone not found', 404)
  end

  def parse_date(v)
    v.present? ? Date.parse(v.to_s) : nil
  rescue ArgumentError
    nil
  end

  def moderated? = ((Client[current_client_id]&.settings || {})['moderate_comments'] == true)

  # Full detail with milestones, discussion and photos. Members only see
  # approved comments.
  def detail_payload(p, member: false)
    cds = App::Models::ProjectComment.where(client_id: current_client_id, project_id: p.id).order(:created_at)
    cds = cds.where(status: 'approved') if member
    p.as_pos(with_updates: true).merge(
      photos:     project_photos(p),
      milestones: p.project_milestones.map(&:as_pos),
      comments:   cds.all.map(&:as_pos),
      reactions:  reaction_summary(p.id)
    )
  end

  def reaction_summary(pid)
    App::Models::ProjectReaction.where(project_id: pid).group_and_count(:kind).all
                                .to_h { |r| [r[:kind] || 'like', r[:count]] }
  end

  def set_vendor(p)
    return if params[:vendor_staff_id].to_s.empty?
    v = App::Models::Staff.where(client_id: current_client_id, id: params[:vendor_staff_id]).first
    p.set(vendor_staff_id: v&.id, vendor_name: v&.name) if v
  end

  def project_photos(p)
    App::Models::Photo
      .where(client_id: current_client_id, attachable_type: 'Project', attachable_id: p.id)
      .order(:created_at).all.map(&:as_pos)
  end

  def coerced
    @coerced ||= begin
      d = data_for(:save)
      d['budget_paise'] = (d.delete('budget').to_f * 100).round if d.key?('budget')
      d
    end
  end

  def counts_by_status
    base = scoped
    { all: base.count, open: base.where(status: Project::OPEN_STATUSES).count,
      completed: base.where(status: 'completed').count }
  end

  def self.fields
    { save: %i[name description budget status start_date target_date
               affected_areas affected_plots] }
  end
end
