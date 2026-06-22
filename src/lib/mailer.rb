# Central mail sender. Builds SMTP delivery options from a per-association
# configuration (stored on the client's settings) and falls back to the
# process-wide ENV config. Each message sets its own delivery_method so
# different associations can use different SMTP providers.
module App
  module Mailer
    module_function

    # Resolve the SMTP config for a client, layering: built-in ENV defaults <-
    # the client's saved `settings['smtp']`. Returns a symbol-keyed hash.
    def config_for(client)
      saved = (client&.settings || {})['smtp'] || {}
      {
        'enabled'    => saved.key?('enabled') ? saved['enabled'] : env_present?,
        'host'       => saved['host'].to_s.empty?     ? ENV['EMAIL_SMTP_SERVER'] : saved['host'],
        'port'       => (saved['port'].to_s.empty?    ? (ENV['EMAIL_PORT'] || 587) : saved['port']).to_i,
        'username'   => saved['username'].to_s.empty? ? ENV['EMAIL_USER'] : saved['username'],
        'password'   => saved['password'].to_s.empty? ? ENV['EMAIL_PASSWORD'] : saved['password'],
        'security'   => (saved['security'].to_s.empty? ? 'starttls' : saved['security']),
        'from_email' => saved['from_email'].to_s.empty? ? (ENV['EMAIL_USER'] || 'noreply@greenaeroview.in') : saved['from_email'],
        'from_name'  => saved['from_name'].to_s.empty? ? (client&.name || 'PlotMate') : saved['from_name'],
        'domain'     => saved['domain'].to_s.empty? ? ENV['EMAIL_DOMAIN'] : saved['domain']
      }
    end

    def env_present?
      !ENV['EMAIL_SMTP_SERVER'].to_s.empty?
    end

    def configured?(client)
      cfg = config_for(client)
      !cfg['host'].to_s.empty? && !cfg['username'].to_s.empty?
    end

    # Translate our friendly config into Mail/Net::SMTP delivery options.
    #   security: 'ssl'      -> implicit TLS (typically port 465)
    #             'starttls' -> opportunistic STARTTLS upgrade (typically 587)
    #             'none'     -> plaintext (dev / internal relays only)
    def smtp_options(cfg)
      opts = {
        address:   cfg['host'],
        port:      cfg['port'].to_i,
        domain:    cfg['domain'].to_s.empty? ? domain_from(cfg['from_email']) : cfg['domain'],
        user_name: cfg['username'],
        password:  cfg['password'],
        authentication: cfg['username'].to_s.empty? ? nil : :login,
        open_timeout: 15,
        read_timeout: 20
      }
      case cfg['security'].to_s
      when 'ssl', 'tls'
        opts[:ssl] = true
      when 'starttls'
        opts[:enable_starttls_auto] = true
      else # 'none'
        opts[:enable_starttls_auto] = false
      end
      opts.compact
    end

    def domain_from(email)
      email.to_s.split('@').last
    end

    # Send one email using the resolved (or explicitly supplied) SMTP config.
    # Raises on failure so callers can surface a precise error to the admin.
    def deliver(to:, subject:, html_body: nil, text_body: nil, client: nil, config: nil, reply_to: nil)
      cfg     = config || config_for(client)

      # Preview mode: don't actually send — just log and report what would go out.
      # Lets an admin verify the whole pipeline with zero mail-server setup.
      if cfg['security'].to_s == 'preview'
        App.logger.info("[Mailer preview] would email #{to} — subject: #{subject}")
        return { preview: true, to: to, subject: subject }
      end

      raise 'SMTP is not configured. Add SMTP details under Settings → Email.' if cfg['host'].to_s.empty?

      # Diagnostic: log the resolved SMTP identity and which source the password
      # came from (never the password itself), so auth failures are debuggable.
      pw_source = if cfg['password'].to_s == ENV['EMAIL_PASSWORD'].to_s && !ENV['EMAIL_PASSWORD'].to_s.empty?
                    'ENV'
                  elsif cfg['password'].to_s.empty?
                    'none'
                  else
                    'saved/posted'
                  end
      App.logger.info("[Mailer] host=#{cfg['host']} port=#{cfg['port']} user=#{cfg['username']} " \
                      "security=#{cfg['security']} pw_len=#{cfg['password'].to_s.length} pw_source=#{pw_source}")

      options   = smtp_options(cfg)
      from_addr = cfg['from_email']
      from_name = cfg['from_name']
      mail = Mail.new
      mail.from     = from_name.to_s.empty? ? from_addr : "#{from_name} <#{from_addr}>"
      mail.to       = to
      mail.subject  = subject
      mail.reply_to = reply_to if reply_to
      if html_body
        mail.html_part = Mail::Part.new do
          content_type 'text/html; charset=UTF-8'
          body html_body
        end
      end
      if text_body || html_body
        plain = text_body || strip_html(html_body)
        mail.text_part = Mail::Part.new { body plain }
      end
      mail.delivery_method :smtp, options
      mail.deliver!
      mail
    end

    def strip_html(html)
      html.to_s.gsub(/<[^>]+>/, ' ').gsub(/\s+/, ' ').strip
    end

    # --- branded email template ----------------------------------------------
    # Wraps message content in a responsive, email-client-safe layout (table
    # based, all-inline CSS). Renders an optional highlighted OTP code and/or a
    # call-to-action button. The association name (when known) personalises the
    # header and footer.
    #
    #   App::Mailer.branded_email(
    #     client:, heading:, intro:, code: '123456',
    #     button_label: 'Reset password', button_url: 'https://…',
    #     outro: 'This code expires in 10 minutes.')
    def branded_email(heading:, intro:, client: nil, code: nil, button_label: nil, button_url: nil, outro: nil)
      brand   = '#047857'  # brand-700
      brand_d = '#065f46'  # brand-800
      org     = (client&.name.to_s.empty? ? 'PlotMate' : client.name)
      year    = Time.now.year

      code_block = if code
        <<~HTML
          <tr><td style="padding:8px 40px 0">
            <div style="margin:8px 0;padding:20px;border:1px solid #e2e8f0;border-radius:12px;background:#f8fafc;text-align:center">
              <div style="font-size:12px;font-weight:600;letter-spacing:.06em;text-transform:uppercase;color:#64748b">Verification code</div>
              <div style="margin-top:10px;font-family:'Courier New',monospace;font-size:34px;font-weight:700;letter-spacing:10px;color:#0f172a">#{code}</div>
            </div>
          </td></tr>
        HTML
      else
        ''
      end

      button_block = if button_label && button_url
        <<~HTML
          <tr><td style="padding:12px 40px 4px">
            <a href="#{button_url}" style="display:inline-block;background:#{brand};color:#ffffff;text-decoration:none;font-size:15px;font-weight:600;padding:13px 28px;border-radius:10px">#{button_label}</a>
          </td></tr>
          <tr><td style="padding:0 40px 4px;font-size:12px;color:#94a3b8;word-break:break-all">Or paste this link into your browser:<br>#{button_url}</td></tr>
        HTML
      else
        ''
      end

      outro_block = outro ? %(<tr><td style="padding:8px 40px 0;font-size:14px;line-height:22px;color:#64748b">#{outro}</td></tr>) : ''

      <<~HTML
        <!doctype html>
        <html lang="en">
        <head><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1"><title>#{heading}</title></head>
        <body style="margin:0;padding:0;background:#f1f5f9;font-family:-apple-system,BlinkMacSystemFont,'Segoe UI',Roboto,Helvetica,Arial,sans-serif;color:#0f172a">
          <table role="presentation" width="100%" cellpadding="0" cellspacing="0" style="background:#f1f5f9;padding:32px 16px">
            <tr><td align="center">
              <table role="presentation" width="100%" cellpadding="0" cellspacing="0" style="max-width:560px;background:#ffffff;border-radius:16px;overflow:hidden;box-shadow:0 1px 3px rgba(15,23,42,.08)">
                <!-- header -->
                <tr><td style="background:linear-gradient(135deg,#{brand},#{brand_d});padding:28px 40px">
                  <table role="presentation" cellpadding="0" cellspacing="0"><tr>
                    <td style="font-size:20px;font-weight:700;color:#ffffff;letter-spacing:-.01em">PlotMate</td>
                  </tr></table>
                  <div style="margin-top:2px;font-size:12px;color:#d1fae5">#{org}</div>
                </td></tr>
                <!-- body -->
                <tr><td style="padding:32px 40px 8px"><h1 style="margin:0;font-size:20px;font-weight:700;color:#0f172a">#{heading}</h1></td></tr>
                <tr><td style="padding:8px 40px 0;font-size:15px;line-height:24px;color:#334155">#{intro}</td></tr>
                #{code_block}
                #{button_block}
                #{outro_block}
                <tr><td style="padding:28px 40px 0"><hr style="border:none;border-top:1px solid #e2e8f0;margin:0"></td></tr>
                <tr><td style="padding:16px 40px 32px;font-size:12px;line-height:20px;color:#94a3b8">
                  If you didn’t request this, you can safely ignore this email — no changes will be made to your account.
                </td></tr>
              </table>
              <div style="max-width:560px;margin:16px auto 0;font-size:11px;color:#94a3b8;text-align:center">
                &copy; #{year} #{org} · Powered by PlotMate · Plot-owners’ association management
              </div>
            </td></tr>
          </table>
        </body>
        </html>
      HTML
    end
  end
end
