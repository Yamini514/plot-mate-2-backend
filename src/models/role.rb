class App::Models::Role < Sequel::Model
  # Catalogue of capabilities a committee role can be granted. These are
  # descriptive (shown in the UI / used by the approval matrix), not wired into
  # the auth middleware — the user auth role enum still gates access.
  PERMISSIONS = %w[
    billing.manage treasury.manage approvals.review documents.manage
    tickets.manage maintenance.manage projects.manage announcements.publish
    members.manage staff.manage settings.manage security.manage
  ].freeze

  def validate
    super
    validates_presence [:client_id, :name]
  end

  def as_pos
    { id: id, name: name, description: description,
      permissions: (permissions || []), active: active.nil? ? true : active }
  end
end
