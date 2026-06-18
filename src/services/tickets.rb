class App::Services::Tickets < App::Services::Base
  def model = Ticket

  def list
    ds = scoped.order(Sequel.desc(:created_at))
    ds = ds.where(status: qs[:status])     if qs[:status].present?   && qs[:status]   != 'all'
    ds = ds.where(category: qs[:category]) if qs[:category].present? && qs[:category] != 'all'
    ds = ds.where(priority: qs[:priority]) if qs[:priority].present? && qs[:priority] != 'all'
    ds = ds.where(created_by_user_id: App.cu.id) if qs[:mine] == 'true'
    if qs[:search].present?
      term = "%#{qs[:search]}%"
      ds = ds.where do
        Sequel.ilike(:code, term) | Sequel.ilike(:subject, term) |
          Sequel.ilike(:created_by_name, term) | Sequel.ilike(:assignee, term) |
          Sequel.ilike(:location, term)
      end
    end
    count = ds.count
    return_success(ds.offset(offset).limit(limit).all.map(&:as_pos),
                   total_pages: (count / page_size.to_f).ceil, counts: counts_by_status)
  end

  def get
    return_success(item.as_pos)
  end

  def create
    obj = model.new(data_for(:save))
    obj.client_id = current_client_id
    obj.code ||= next_code
    obj.status = 'created'
    obj.reopen_count = 0
    obj.created_by_name ||= "#{App.cu.user_obj.full_name} (#{App.cu.user_obj.role_name.capitalize})"
    obj.created_by_user_id ||= App.cu.id
    obj.due_at = Time.now + (Ticket::SLA_HOURS[obj.priority] || 24) * 3600
    save(obj) { |t| return_success(t.as_pos) }
  end

  def update
    data = data_for(:save)
    item.set_fields(data, data.keys)
    save(item) { |t| return_success(t.as_pos) }
  end

  # Workflow transition (validated by the state machine).
  def transition
    to = params[:to].to_s
    unless item.transition!(to)
      return_errors!("Cannot move #{item.code} from '#{item.status}' to '#{to}'", 422)
    end
    return_success(item.as_pos)
  end

  # Auto-assign by category, or assign to a named person.
  def assign
    if params[:assignee].present?
      item.assignee = params[:assignee]
      item.status = 'assigned' if item.status == 'created'
      save(item) { |t| return_success(t.as_pos) }
    else
      item.auto_assign!
      return_success(item.as_pos)
    end
  end

  def escalate
    item.status = 'escalated'
    save(item) { |t| return_success(t.as_pos) }
  end

  # Member confirms resolution: accept (close + rate) or reopen.
  def verify
    return_errors!('Forbidden', 403) unless item.created_by_user_id == App.cu.id
    case params[:action].to_s
    when 'accept'
      item.status = 'closed'
      item.rating = params[:rating]&.to_i
      save(item) { |t| return_success(t.as_pos) }
    when 'reopen'
      unless item.transition!('reopened')
        item.status = 'reopened'
        item.reopen_count = (item.reopen_count || 0) + 1
        item.resolved_at = nil
        item.save_changes
      end
      return_success(item.as_pos)
    else
      return_errors!('Invalid action', 400)
    end
  end

  # Helpdesk dashboard widgets.
  def summary
    rows = scoped.all
    by   = ->(s) { rows.count { |t| t.status == s } }
    done = rows.select { |t| t.resolved_at && t.created_at }
    avg  = done.empty? ? 0 : (done.sum { |t| t.resolved_at - t.created_at } / done.length / 3600.0).round(1)
    return_success(
      total:              rows.length,
      open:               rows.count { |t| Ticket::OPEN_STATUSES.include?(t.status) },
      in_progress:        by.call('in_progress'),
      resolved:           by.call('resolved'),
      closed:             by.call('closed'),
      escalated:          by.call('escalated'),
      overdue:            rows.count { |t| t.sla_state == 'breached' },
      reopened:           rows.count { |t| (t.reopen_count || 0).positive? },
      avg_resolution_hrs: avg,
      sla_compliance:     rows.empty? ? 100 : ((rows.count { |t| t.sla_state != 'breached' } * 100.0) / rows.length).round,
      staff_performance: rows.reject { |t| t.assignee.nil? }.group_by(&:assignee)
                             .map { |a, l| { name: a, value: l.length } }
                             .sort_by { |x| -x[:value] }.first(6),
      sla_by_priority: %w[critical high medium low].map do |p|
        within = rows.select { |t| t.priority == p }
        ok = within.count { |t| t.sla_state != 'breached' }
        { name: p.capitalize, value: within.empty? ? 100 : (ok * 100 / within.length) }
      end,
      category_distribution: rows.group_by(&:category).map { |c, l| { name: c, value: l.length } },
      status_distribution: [
        { name: 'Open',      value: rows.count { |t| Ticket::OPEN_STATUSES.include?(t.status) } },
        { name: 'Resolved',  value: by.call('resolved') },
        { name: 'Closed',    value: by.call('closed') },
        { name: 'Escalated', value: by.call('escalated') }
      ]
    )
  end

  def export_csv
    ds = scoped.order(Sequel.desc(:created_at))
    csv = CSV.generate do |out|
      out << %w[Ticket Subject Category Priority Status Assignee SLA Created]
      ds.each do |t|
        out << [t.code, t.subject, t.category, t.priority, t.status, t.assignee, t.sla_remaining, t.created_at]
      end
    end
    r.response['Content-Type'] = 'text/csv'
    r.response['Content-Disposition'] = 'attachment; filename="tickets.csv"'
    csv
  end

  def item(id = rp[:id])
    @item ||= scoped[id] || return_errors!('Ticket not found', 404)
  end

  private

  def counts_by_status
    c = scoped.group_and_count(:status).all
              .each_with_object({}) { |r, h| h[r[:status]] = r[:count] }
    c['all'] = scoped.count
    c
  end

  def next_code
    "TKT-#{4811 + scoped.count}"
  end

  def self.fields
    { save: %i[subject description category priority location] }
  end
end
