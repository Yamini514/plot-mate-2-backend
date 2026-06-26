require 'time' # Time.parse for the from/to date filters

class App::Services::AuditLogs < App::Services::Base
  # Read-only platform audit trail. Append-only — no create/update/delete here.
  def model = AuditLog

  SORTABLE = { 'action' => :action, 'actor' => :actor_name,
               'entity' => :entity_type, 'created_at' => :created_at }.freeze

  def list
    ds = AuditLog.dataset
    ds = ds.where(action: qs[:action])           if qs[:action].present?
    ds = ds.where(entity_type: qs[:entity_type]) if qs[:entity_type].present?
    ds = ds.where(client_id: qs[:client_id].to_i) if qs[:client_id].present?
    ds = ds.where(actor_id: qs[:actor_id].to_i)  if qs[:actor_id].present?
    ds = ds.where { created_at >= Time.parse(qs[:from]) } if qs[:from].present?
    ds = ds.where { created_at <= Time.parse(qs[:to]) }   if qs[:to].present?
    if qs[:search].present?
      term = "%#{qs[:search]}%"
      ds = ds.where { Sequel.ilike(:summary, term) | Sequel.ilike(:actor_name, term) }
    end

    ds    = apply_sort(ds, SORTABLE)
    total = ds.count
    return_success(ds.offset(offset).limit(limit).all.map(&:as_pos),
                   actions: AuditLog.distinct.select_map(:action).compact.sort,
                   **pagination_meta(total))
  rescue ArgumentError
    return_errors!('Invalid date filter', 422)
  end
end
