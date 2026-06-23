# Process-wide SMTP fallback. Only configured when EMAIL_SMTP_SERVER is set, so
# we don't install broken (all-nil) defaults on boot. Per-association sending is
# handled by App::Mailer, which sets delivery options per message; this default
# is only used by any `Mail#deliver!` call that doesn't override delivery_method.
if !ENV['EMAIL_SMTP_SERVER'].to_s.empty?
  port = (ENV['EMAIL_PORT'] || 465).to_i
  LOGGER.info "SMTP HOST=#{ENV['EMAIL_SMTP_SERVER']}"
  LOGGER.info "SMTP PORT=#{ENV['EMAIL_PORT']}"
  LOGGER.info "SMTP USER=#{ENV['EMAIL_USER']}"
  LOGGER.info "SMTP SSL=#{port == 465}"
  LOGGER.info "SMTP STARTTLS=#{port != 465}"
  options = {
    address: ENV['EMAIL_SMTP_SERVER'],
    port: port,
    domain: ENV['EMAIL_DOMAIN'] || ENV['EMAIL_DOMAN'], # tolerate the legacy misspelled key
    user_name: ENV['EMAIL_USER'],
    password: ENV['EMAIL_PASSWORD'],
    authentication: 'plain',
    enable_starttls_auto: port != 465,
    ssl: port == 465
  }

  Mail.defaults do
    delivery_method :smtp, options
    
  end
end
