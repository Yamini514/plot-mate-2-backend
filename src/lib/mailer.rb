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
  end
end
