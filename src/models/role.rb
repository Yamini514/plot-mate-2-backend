class App::Models::Role < Sequel::Model
  # Permission catalogue: module → granted actions. A role's `permissions` jsonb
  # holds the flat "module.action" keys it's granted (e.g. "payments.approve").
  # Enforced by App::Permissions + permission_required! (not just descriptive).
  MODULES = {
    'dashboard'   => %w[view],
    'plots'       => %w[view create edit delete export],
    'owners'      => %w[view create edit delete export approve],
    'committee'   => %w[view create edit delete assign],
    'vendors'     => %w[view create edit delete assign export],
    'workorders'  => %w[view create edit delete assign approve export],
    'complaints'  => %w[view create edit delete assign approve export],
    'maintenance' => %w[view create edit delete assign],
    'payments'    => %w[view create approve export configure],
    'finance'     => %w[view create edit approve export configure],
    'projects'    => %w[view create edit delete assign],
    'documents'   => %w[view create edit delete approve],
    'notices'     => %w[view create edit delete],
    'reports'     => %w[view export],
    'settings'    => %w[view configure],
    'support'     => %w[view create edit assign],
    'analytics'   => %w[view export]
  }.freeze

  # Flat list of every valid permission key ("module.action").
  PERMISSIONS = MODULES.flat_map { |mod, actions| actions.map { |a| "#{mod}.#{a}" } }.freeze

  # Legacy coarse keys (pre-RBAC) → new keys, so old role rows keep working.
  LEGACY_MAP = {
    'billing.manage' => %w[payments.view payments.approve finance.view],
    'treasury.manage' => %w[finance.view finance.approve finance.export],
    'approvals.review' => %w[owners.approve complaints.approve],
    'documents.manage' => %w[documents.view documents.create documents.approve],
    'tickets.manage' => %w[workorders.view workorders.assign complaints.view],
    'maintenance.manage' => %w[maintenance.view maintenance.create maintenance.assign],
    'projects.manage' => %w[projects.view projects.create projects.edit],
    'announcements.publish' => %w[notices.view notices.create],
    'members.manage' => %w[owners.view owners.create owners.edit],
    'staff.manage' => %w[committee.view committee.create vendors.view],
    'settings.manage' => %w[settings.view settings.configure],
    'security.manage' => %w[support.view]
  }.freeze

  # Default committee/staff role templates (name → granted permission keys).
  # Seeded per venture so admins start with sensible roles they can edit/clone.
  TEMPLATES = {
    'President' => %w[dashboard.view analytics.view analytics.export reports.view reports.export
                      owners.view complaints.view complaints.approve payments.view finance.view
                      finance.approve projects.view notices.view notices.create],
    'Vice President' => %w[dashboard.view analytics.view reports.view owners.view complaints.view
                           complaints.approve projects.view notices.view],
    'Secretary' => %w[dashboard.view notices.view notices.create notices.edit notices.delete
                      documents.view documents.create documents.edit documents.approve reports.view],
    'Joint Secretary' => %w[dashboard.view notices.view notices.create documents.view documents.create],
    'Treasurer' => %w[dashboard.view payments.view payments.create payments.approve payments.export
                      finance.view finance.create finance.edit finance.approve finance.export
                      reports.view reports.export owners.view],
    'Maintenance Manager' => %w[dashboard.view complaints.view complaints.assign complaints.approve
                                workorders.view workorders.assign workorders.approve workorders.export
                                vendors.view vendors.assign maintenance.view maintenance.create
                                maintenance.assign projects.view projects.edit],
    'Facility Manager' => %w[dashboard.view maintenance.view maintenance.create maintenance.assign
                             workorders.view workorders.assign notices.view],
    'Accountant' => %w[dashboard.view payments.view payments.approve payments.export finance.view
                       finance.create finance.edit finance.export reports.view reports.export owners.view],
    'Receptionist' => %w[dashboard.view owners.view owners.create support.view support.create
                         support.assign documents.view documents.create reports.view],
    'Office Staff' => %w[dashboard.view owners.view documents.view documents.create support.view
                         support.create notices.view],
    'Security Manager' => %w[dashboard.view support.view support.create support.edit support.assign]
  }.freeze

  def validate
    super
    validates_presence [:client_id, :name]
  end

  # Create the default role templates for a venture if it has none yet.
  def self.seed_templates!(client_id)
    return 0 if where(client_id: client_id).count.positive?
    TEMPLATES.sum do |name, perms|
      create(client_id: client_id, name: name, permissions: perms, active: true, is_template: true)
      1
    end
  rescue StandardError => e
    App.logger.error("Role.seed_templates! failed: #{e.message}")
    0
  end

  # Granted permissions, normalised: expands any legacy coarse keys to the new
  # module.action set and drops anything not in the catalogue.
  def effective_permissions
    raw = permissions || []
    expanded = raw.flat_map { |p| LEGACY_MAP[p] || [p] }
    (expanded & PERMISSIONS).uniq
  end

  def as_pos
    { id: id, name: name, description: description,
      permissions: effective_permissions, active: active.nil? ? true : active,
      is_template: (respond_to?(:is_template) ? !!is_template : false) }
  end
end
