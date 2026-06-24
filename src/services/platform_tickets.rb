class App::Services::PlatformTickets < App::Services::Base
  # Venture ↔ platform support tickets. Not tenant-scoped (the super admin sees
  # every venture's tickets). A Venture Admin raising one is handled by the
  # venture app; here the super admin triages, assigns, replies and escalates.
  def model = PlatformTicket

  def list
    ds = PlatformTicket.order(Sequel.desc(:created_at))
    ds = ds.where(status: qs[:status])     if qs[:status].present? && qs[:status] != 'all'
    ds = ds.where(priority: qs[:priority]) if qs[:priority].present?
    ds = ds.where(client_id: qs[:client_id].to_i) if qs[:client_id].present?
    if qs[:search].present?
      term = "%#{qs[:search]}%"
      ds = ds.where { Sequel.ilike(:subject, term) | Sequel.ilike(:code, term) }
    end
    tickets = ds.all
    names   = Client.where(id: tickets.map(&:client_id).compact.uniq).select_hash(:id, :name)
    return_success(tickets.map { |t| t.as_pos.merge(venture: names[t.client_id]) },
                   counts: counts_by_status)
  end

  def get
    t = item
    venture = t.client_id ? Client[t.client_id]&.name : nil
    return_success(t.as_pos(with_messages: true).merge(venture: venture))
  end

  # Super admin can also open a ticket about a venture.
  def create
    obj = PlatformTicket.new(data_for(:save))
    obj.code   ||= "PT-#{1001 + PlatformTicket.count}"
    obj.status ||= 'open'
    obj.raised_by      ||= App.cu.id
    obj.raised_by_name ||= App.cu.user_obj&.full_name
    save(obj) { |t| return_success(t.as_pos) }
  end

  def assign
    item.set(assigned_to: params[:assigned_to] || App.cu.id,
             status: item.status == 'open' ? 'assigned' : item.status)
    save(item) do
      App::Audit.record('ticket.assign', entity: item, client_id: item.client_id,
                        summary: "Assigned #{item.code}", meta: { assigned_to: item.assigned_to })
      return_success(item.as_pos)
    end
  end

  def update_status
    status = params[:status].to_s
    return_errors!('Unknown status', 422) unless PlatformTicket::STATUSES.include?(status)
    item.set(status: status, resolved_at: (status == 'resolved' ? Time.now : item.resolved_at))
    save(item) do
      App::Audit.record('ticket.status', entity: item, client_id: item.client_id,
                        summary: "#{item.code} → #{status}")
      return_success(item.as_pos)
    end
  end

  def reply
    msg = PlatformTicketMessage.new(
      platform_ticket_id: item.id, author_id: App.cu.id,
      author_name: App.cu.user_obj&.full_name, author_role: App.cu.user_obj&.role_name,
      body: params[:body], internal: !!params[:internal]
    )
    # A reply (not an internal note) moves an open ticket forward.
    item.update(status: 'waiting_venture') if !params[:internal] && item.status == 'open'
    save(msg) { return_success(msg.as_pos) }
  end

  def escalate
    next_level = { 'l1' => 'l2', 'l2' => 'l3', 'l3' => 'l3' }[item.escalation_level || 'l1']
    item.set(escalation_level: next_level, status: 'escalated', priority: 'high')
    save(item) do
      App::Audit.record('ticket.escalate', entity: item, client_id: item.client_id,
                        summary: "Escalated #{item.code} to #{next_level}")
      return_success(item.as_pos)
    end
  end

  def item(id = rp[:id]) = (@item ||= PlatformTicket[id] || return_errors!('Ticket not found', 404))

  private

  def counts_by_status
    c = PlatformTicket.group_and_count(:status).all
                      .each_with_object({}) { |r, h| h[r[:status]] = r[:count] }
    c['all'] = PlatformTicket.count
    c
  end

  def self.fields
    { save: %i[client_id subject description category priority] }
  end
end
