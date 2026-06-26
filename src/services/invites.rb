class App::Services::Invites < App::Services::Base
  # Admin-issued, token-based onboarding invites. The venture admin creates an
  # invite (member/owner, optionally pre-linked to a plot); the recipient opens
  # the link and self-completes their profile + KYC, which raises an
  # owner_verification approval request for the admin to review. No open public
  # signup — an invite must exist first.
  def model = Invite

  def frontend_url = ENV['FRONTEND_URL'].to_s.chomp('/')

  # --- admin -----------------------------------------------------------------
  def list
    ds = scoped.order(Sequel.desc(:created_at))
    ds = ds.where(status: qs[:status]) if qs[:status].present? && qs[:status] != 'all'
    return_success(ds.all.map { |i| i.as_pos }, counts: counts_by_status)
  end

  def create
    inv = Invite.new(
      client_id:  current_client_id,
      email:      params[:email].to_s.strip.downcase.presence,
      full_name:  params[:full_name].presence,
      role:       (params[:role] || User::ROLES[:member]).to_i,
      plot_id:    params[:plot_id].presence,
      token:      SecureRandom.urlsafe_base64(24),
      status:     'pending',
      invited_by: App.cu.id,
      expires_at: Time.now + Invite::DEFAULT_TTL
    )
    inv.code ||= "INV-#{1001 + Invite.where(client_id: current_client_id).count}"
    save(inv) do |i|
      App::Audit.record('invite.create', entity: i, client_id: current_client_id,
                        summary: "Invited #{i.email || i.full_name} (#{i.role_name})")
      maybe_email(i)
      return_success(i.as_pos(with_token: true).merge(invite_url: invite_url(i)))
    end
  end

  # Re-issue: fresh token + window, so a lost/expired link can be re-sent.
  def resend
    return_errors!('Only pending invites can be resent', 422) unless item.pending?
    item.set(token: SecureRandom.urlsafe_base64(24), expires_at: Time.now + Invite::DEFAULT_TTL)
    save(item) do
      maybe_email(item)
      return_success(item.as_pos(with_token: true).merge(invite_url: invite_url(item)))
    end
  end

  def revoke
    item.set(status: 'revoked')
    save(item) { return_success(item.as_pos) }
  end

  def item(id = rp[:id]) = (@item ||= scoped[id] || return_errors!('Invite not found', 404))

  # --- public (no auth) — keyed by token, never by client --------------------
  def show
    inv = by_token
    return_errors!('This invite link is invalid or has expired', 404) unless inv&.usable?
    plot    = inv.plot_id ? Plot[inv.plot_id] : nil
    client  = Client[inv.client_id]
    inviter = inv.invited_by ? User[inv.invited_by] : nil
    return_success(inv.as_public.merge(
      plot_no:         plot&.plot_no,
      community:       client&.name,
      invited_by_name: inviter&.full_name,
      expires_at:      inv.expires_at
    ))
  end

  # The recipient completes their profile + KYC. Creates the login (role from
  # the invite), links the plot if pre-set, and opens an owner_verification
  # request so the admin verifies before the account is fully trusted.
  def accept
    inv = by_token
    return_errors!('This invite link is invalid or has expired', 404) unless inv&.usable?

    email = (params[:email].presence || inv.email).to_s.strip.downcase
    return_errors!('Email is required', 422) if email.empty?
    return_errors!('Password is required', 422) if params[:password].to_s.empty?
    if User.where(email: email, active: true).first
      return_errors!('An account with this email already exists. Please sign in instead.', 422)
    end

    user = User.new(full_name: params[:full_name].presence || inv.full_name, email: email,
                    phone_number: params[:phone_number].presence, role: inv.role,
                    client_id: inv.client_id, active: true)
    user.password = params[:password]
    user.set(kyc_status: 'submitted', kyc_data: (params[:kyc_data] || {}))
    user.extras = (user.extras || {}).merge('title' => title_for(inv.role))

    ok = App.db.transaction do
      raise Sequel::Rollback unless user.save
      link_plot!(inv, user)
      inv.set(status: 'accepted', user_id: user.id, accepted_at: Time.now)
      inv.save_changes
      App::Models::ApprovalRequest.open!(
        client_id: inv.client_id, request_type: 'owner_verification',
        subject_type: 'User', subject_id: user.id,
        payload: { 'user_id' => user.id, 'plot_id' => inv.plot_id },
        submitted_by: user.id, submitted_by_name: user.full_name
      )
      true
    end

    return return_success(message: 'Profile submitted — your account is pending admin verification.') if ok
    return_errors!('Could not complete the invite. Please try again.', 422)
  end

  private

  def by_token
    @by_token ||= Invite.where(token: rp[:token].to_s).first
  end

  def invite_url(inv) = "#{frontend_url}/invite/#{inv.token}"

  def title_for(role)
    role.to_i == User::ROLES[:admin] ? 'Committee Member' : 'Owner'
  end

  # Pre-linked plot: stamp the owner's details and mark it booked/unverified so
  # the admin's approval flips it to verified (mirrors register-owner).
  def link_plot!(inv, user)
    return unless inv.plot_id
    plot = Plot.where(client_id: inv.client_id, id: inv.plot_id).first
    return unless plot
    plot.set(owner_name: user.full_name, email: user.email, phone: user.phone_number,
             status: 'booked', membership: 'unverified')
    plot.save_changes
  rescue => e
    App.logger.error("link_plot! failed: #{e.message}")  # non-fatal
  end

  # Best-effort email of the invite link (uses the venture's configured SMTP).
  def maybe_email(inv)
    return if inv.email.to_s.empty?
    client = Client[inv.client_id]
    html = App::Mailer.branded_email(
      client: client, heading: "You're invited to #{client&.name || 'PlotMate'}",
      intro: "Hello #{inv.full_name || ''}, you've been invited to join your community portal. " \
             'Click below to set up your account and complete your profile.',
      button_label: 'Accept invite', button_url: invite_url(inv),
      outro: 'This link expires in 14 days.'
    )
    App::Mailer.deliver(to: inv.email, subject: 'Your invitation to PlotMate', html_body: html, client: client)
  rescue => e
    App.logger.error("invite email failed: #{e.message}")  # non-fatal — link is also shown in-app
  end

  def counts_by_status
    base = scoped
    { all: base.count, pending: base.where(status: 'pending').count,
      accepted: base.where(status: 'accepted').count,
      revoked: base.where(status: 'revoked').count }
  end
end
