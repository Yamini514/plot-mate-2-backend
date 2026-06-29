class App::Services::Settings < App::Services::Base
  # Per-venture configurable lists — categories, priorities, SLA, channels — so
  # nothing is hardcoded. Stored under settings['lists'], deep-merged over these
  # defaults, and surfaced to both admin and member apps via public_settings.
  DEFAULT_LISTS = {
    'complaint_categories' => %w[Electricity Water Roads Drainage Security Cleaning Other],
    'complaint_priorities' => %w[low medium high critical],
    'document_categories'  => ['Legal', 'Financial', 'Meeting Minutes', 'Layout', 'Maintenance', 'Other'],
    'ticket_categories'    => %w[maintenance security electrical plumbing cleaning amenities parking documentation billing community other],
    'ticket_sla_hours'     => { 'low' => 72, 'medium' => 24, 'high' => 8, 'critical' => 1 },
    'announcement_channels' => %w[in_app email whatsapp],
    # --- Security / gate lists ---
    'visitor_types'        => %w[Guest Family Delivery Cab Vendor Other],
    'vehicle_types'        => %w[Car Bike Commercial Emergency Other],
    'delivery_companies'   => ['Amazon', 'Flipkart', 'Swiggy', 'Zomato', 'Blue Dart', 'DTDC', 'India Post', 'Other'],
    'domestic_staff_types' => %w[Maid Driver Gardener Housekeeping Cook Electrician Plumber Other],
    'incident_categories'  => ['Theft', 'Trespassing', 'Fire', 'Medical', 'Altercation', 'Vandalism', 'Other']
  }.freeze

  # Effective lists for a venture (stored over defaults). Callers needing a
  # configurable enum read this rather than a hardcoded constant.
  def self.lists_for(client)
    DEFAULT_LISTS.merge((client&.settings || {})['lists'] || {})
  end

  # Association config stored on the client (rate, bank, committee, SMTP, etc.).
  # A platform-level super admin has no client, so return empty config rather
  # than erroring — the shell then falls back to neutral defaults.
  def show
    c = current_client_id && Client[current_client_id]
    return return_success({}) unless c
    return_success(public_settings(c))
  end

  def update
    c = Client[current_client_id]
    incoming = (params || {}).reject { |k, _| %w[name email].include?(k.to_s) }
    incoming = merge_smtp(c, incoming)
    incoming = merge_whatsapp(c, incoming)
    c.settings = (c.settings || {}).merge(incoming)
    c.name  = params[:name]  if params[:name].present?
    c.email = params[:email] if params[:email].present?
    save(c) { return_success(public_settings(c)) }
  end

  # Send a one-off test email so the admin can verify SMTP before relying on it.
  # Tests with the just-entered config (if posted) so they can validate prior to
  # saving; a blank password falls back to the stored/ENV one.
  def test_email
    c  = Client[current_client_id]
    to = params[:to].presence || App.cu.user_obj.email
    return_errors!('Enter a recipient email address', 400) if to.to_s.strip.empty?

    cfg     = test_config(c)
    subject = "PlotMate test email — #{c.name}"
    html    = "<p>Hello,</p>" \
              "<p>This is a test email from <b>#{c.name}</b>'s PlotMate setup.</p>" \
              "<p>If you're reading this, your SMTP settings are working correctly. 🎉</p>" \
              "<p style=\"color:#94a3b8;font-size:12px\">Sent from PlotMate · Settings → Email</p>"

    # Preview mode renders the email without sending — a zero-setup sanity check.
    if cfg['security'].to_s == 'preview'
      App.logger.info("[Mail preview] to=#{to} subject=#{subject}")
      return return_success(
        preview: { to: to.to_s.strip, from: "#{cfg['from_name']} <#{cfg['from_email']}>", subject: subject, html: html },
        message: 'Preview generated — email was NOT actually sent (Preview mode).'
      )
    end

    App::Mailer.deliver(to: to.to_s.strip, subject: subject, html_body: html, config: cfg)
    return_success(message: "Test email sent to #{to}.")
  rescue => e
    App.logger.error("Test email failed: #{e.class}: #{e.message}")
    return_errors!("Couldn't send the test email: #{e.message}", 422)
  end

  private

  def admin?
    App.cu.user_obj&.admin?
  end

  # The client config shaped for the frontend. Secrets are never sent back (only
  # a `*_set` flag); non-admins don't receive the credential-bearing config at all.
  def public_settings(c)
    s = (c.settings || {}).dup
    if s['smtp'].is_a?(Hash)
      if admin?
        smtp = s['smtp'].dup
        smtp['password_set'] = !smtp['password'].to_s.empty?
        smtp.delete('password')
        s = s.merge('smtp' => smtp)
      else
        s = s.reject { |k, _| k.to_s == 'smtp' }
      end
    end
    if s['whatsapp'].is_a?(Hash)
      if admin?
        wa = s['whatsapp'].dup
        wa['access_token_set'] = !wa['access_token'].to_s.empty?
        wa.delete('access_token')
        s = s.merge('whatsapp' => wa)
      else
        s = s.reject { |k, _| k.to_s == 'whatsapp' }
      end
    end
    s.merge(name: c.name, email: c.email, 'lists' => self.class.lists_for(c),
            'features' => feature_payload(c))
  end

  # Enabled-feature map + the admin nav hrefs to hide, so the frontend can gate
  # modules off the same per-venture toggles the super admin controls.
  def feature_payload(c)
    r = App::Services::PlatformFeatures::Resolver
    { 'enabled' => r.state_map(c), 'disabled_nav' => r.disabled_nav(c) }
  rescue StandardError
    { 'enabled' => {}, 'disabled_nav' => [] }
  end

  # Preserve the stored SMTP password when the incoming payload leaves it blank
  # (the frontend never receives the password, so blank means "unchanged").
  def merge_smtp(c, incoming)
    return incoming unless incoming['smtp'].is_a?(Hash)
    existing = (c.settings || {})['smtp'] || {}
    smtp = incoming['smtp'].to_h.dup
    smtp.delete('password_set')
    smtp['password'] = existing['password'] if smtp['password'].to_s.empty?
    incoming.merge('smtp' => smtp)
  end

  # Preserve the stored WhatsApp access token when the incoming payload leaves it
  # blank (the frontend never receives the token, so blank means "unchanged").
  def merge_whatsapp(c, incoming)
    return incoming unless incoming['whatsapp'].is_a?(Hash)
    existing = (c.settings || {})['whatsapp'] || {}
    wa = incoming['whatsapp'].to_h.dup
    wa.delete('access_token_set')
    wa['access_token'] = existing['access_token'] if wa['access_token'].to_s.empty?
    incoming.merge('whatsapp' => wa)
  end

  # Layer any just-entered (non-blank) SMTP fields over the saved/ENV config.
  def test_config(c)
    base   = App::Mailer.config_for(c)
    posted = params[:smtp]
    return base unless posted.is_a?(Hash)
    overrides = posted.to_h.reject { |_, v| v.to_s.strip.empty? }.transform_keys(&:to_s)
    base.merge(overrides)
  end
end
