module App
  # Central RBAC resolver. Resolves the effective permission set for a user and
  # answers allow? checks. The venture owner-admin (user-enum admin = 2 with NO
  # role_id) and the super admin implicitly hold ALL permissions; a committee/
  # staff user (admin = 2 WITH a role_id) is gated by that role's permissions.
  #
  #   App::Permissions.allow?(user, 'payments.approve')
  module Permissions
    module_function

    ALL = :all

    # Effective permission list for a user (array of "module.action", or :all).
    def for(user)
      return [] if user.nil?
      return ALL if user.super_admin?
      return [] unless user.admin?
      rid = user.respond_to?(:role_id) ? user.role_id : nil
      return ALL if rid.nil?
      role = App::Models::Role[rid]
      return [] if role.nil?
      return [] if role.respond_to?(:active) && role.active == false
      role.effective_permissions
    rescue StandardError => e
      App.logger.error("Permissions.for failed: #{e.message}")
      []
    end

    def allow?(user, perm)
      perms = self.for(user)
      perms == ALL || perms.include?(perm.to_s)
    end

    # True when the user is the unrestricted venture owner-admin / super admin.
    def all_access?(user)
      self.for(user) == ALL
    end
  end
end
