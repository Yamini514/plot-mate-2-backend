# Central WhatsApp sender (Meta WhatsApp Business Cloud API). Mirrors App::Mailer:
# resolves a per-association configuration (stored on the client's settings) and
# falls back to the process-wide ENV config, so different associations can use
# their own WhatsApp number / token. Business-initiated messages (OTP, dues
# reminders) must use templates pre-approved in the Meta WhatsApp Manager.
require 'net/http'
require 'uri'
require 'json'

module App
  module WhatsApp
    module_function

    DEFAULT_API_VERSION = 'v25.0'
    GRAPH_HOST = 'graph.facebook.com'

    def blank?(value)
      value.to_s.strip.empty?
    end

    # Resolve the WhatsApp config for a client, layering: built-in ENV defaults
    # <- the client's saved `settings['whatsapp']`. Returns a string-keyed hash.
    def config_for(client)
      saved = (client&.settings || {})['whatsapp'] || {}
      {
        'enabled'           => globally_disabled? ? false : (saved.key?('enabled') ? saved['enabled'] : env_present?),
        'phone_number_id'   => blank?(saved['phone_number_id'])   ? ENV['WHATSAPP_PHONE_NUMBER_ID'] : saved['phone_number_id'],
        'access_token'      => blank?(saved['access_token'])      ? ENV['WHATSAPP_ACCESS_TOKEN'] : saved['access_token'],
        # Not used for sending — kept for reference / future template management.
        'business_account_id' => blank?(saved['business_account_id']) ? ENV['WHATSAPP_BUSINESS_ACCOUNT_ID'] : saved['business_account_id'],
        'api_version'       => blank?(saved['api_version'])       ? (ENV['WHATSAPP_API_VERSION'] || DEFAULT_API_VERSION) : saved['api_version'],
        'country_code'      => blank?(saved['country_code'])      ? (ENV['WHATSAPP_COUNTRY_CODE'] || '91') : saved['country_code'],
        'otp_template'      => blank?(saved['otp_template'])      ? (ENV['WHATSAPP_OTP_TEMPLATE'] || 'plotmate_otp') : saved['otp_template'],
        'otp_lang'          => blank?(saved['otp_lang'])          ? (ENV['WHATSAPP_OTP_LANG'] || 'en_US') : saved['otp_lang'],
        # Authentication-category OTP templates carry a copy-code button that also
        # takes the code as a parameter. Turn this off for a plain body-only template.
        'otp_copy_code'     => saved.key?('otp_copy_code') ? saved['otp_copy_code'] : true,
        'reminder_template' => blank?(saved['reminder_template']) ? (ENV['WHATSAPP_REMINDER_TEMPLATE'] || 'plotmate_reminder') : saved['reminder_template'],
        'reminder_lang'     => blank?(saved['reminder_lang'])     ? (ENV['WHATSAPP_REMINDER_LANG'] || 'en_US') : saved['reminder_lang']
      }
    end

    def env_present?
      !ENV['WHATSAPP_PHONE_NUMBER_ID'].to_s.empty? && !ENV['WHATSAPP_ACCESS_TOKEN'].to_s.empty?
    end

    # Platform-wide kill switch. When WHATSAPP_DISABLED is truthy, no WhatsApp
    # message is sent for any association, regardless of per-venture settings or
    # credentials — lets ops turn the channel off everywhere at once.
    def globally_disabled?
      %w[1 true yes on].include?(ENV['WHATSAPP_DISABLED'].to_s.strip.downcase)
    end

    # Credentials present (regardless of the enabled toggle).
    def configured?(client, cfg = nil)
      cfg ||= config_for(client)
      !blank?(cfg['phone_number_id']) && !blank?(cfg['access_token'])
    end

    # Turn an Indian-style 10-digit (or already country-prefixed) number into the
    # E.164 digits Meta expects (no leading '+'). Returns nil for unusable input.
    def normalize_phone(raw, country_code = '91')
      digits = raw.to_s.gsub(/\D/, '')
      return nil if digits.empty?
      digits = digits.sub(/\A0+/, '') # drop national trunk zeros
      cc = country_code.to_s.gsub(/\D/, '')
      digits = "#{cc}#{digits}" if digits.length <= 10 && !cc.empty?
      digits
    end

    # Low-level send to the Cloud API. Raises on any non-2xx so callers can
    # surface a precise error (mirrors App::Mailer.deliver's raise-on-failure).
    def deliver(to:, type:, payload:, client: nil, config: nil)
      raise 'WhatsApp messaging is disabled on this server.' if globally_disabled?

      cfg = config || config_for(client)
      raise 'WhatsApp is not configured. Add credentials under Settings → WhatsApp.' unless configured?(client, cfg)

      phone = normalize_phone(to, cfg['country_code'])
      raise 'No valid phone number to message.' if phone.nil?

      version = blank?(cfg['api_version']) ? DEFAULT_API_VERSION : cfg['api_version']
      uri  = URI("https://#{GRAPH_HOST}/#{version}/#{cfg['phone_number_id']}/messages")
      body = { messaging_product: 'whatsapp', to: phone, type: type }.merge(payload)

      App.logger.info("[WhatsApp] to=#{phone} type=#{type} phone_id=#{cfg['phone_number_id']} version=#{version}")

      http = Net::HTTP.new(uri.host, uri.port)
      http.use_ssl     = true
      http.open_timeout = 15
      http.read_timeout = 20

      req = Net::HTTP::Post.new(uri)
      req['Authorization'] = "Bearer #{cfg['access_token']}"
      req['Content-Type']  = 'application/json'
      req.body = body.to_json

      res    = http.request(req)
      parsed = (JSON.parse(res.body) rescue {})
      unless res.is_a?(Net::HTTPSuccess)
        detail = parsed.dig('error', 'message') || res.body.to_s
        raise "WhatsApp API error (#{res.code}): #{detail}"
      end
      { ok: true, id: parsed.dig('messages', 0, 'id'), to: phone }
    end

    # --- template helpers ----------------------------------------------------

    # Send a 6-digit reset code. Defaults to an Authentication-category template:
    # body parameter {{1}} = code, plus a copy-code URL button that also receives
    # the code. Set otp_copy_code = false if your template has no button.
    def send_otp(to:, code:, client: nil, config: nil)
      cfg = config || config_for(client)
      components = [{ type: 'body', parameters: [{ type: 'text', text: code.to_s }] }]
      if cfg['otp_copy_code']
        components << {
          type: 'button', sub_type: 'url', index: '0',
          parameters: [{ type: 'text', text: code.to_s }]
        }
      end
      deliver(
        to: to, type: 'template', client: client, config: cfg,
        payload: { template: {
          name: cfg['otp_template'],
          language: { code: cfg['otp_lang'] },
          components: components
        } }
      )
    end

    # Send a dues reminder. Body parameters, in order: owner name, amount (₹),
    # plot number, association name — so the approved template body should read
    # like "Dear {{1}}, … fee of {{2}} for plot {{3}} at {{4}} is pending …".
    def send_reminder(to:, owner_name:, amount:, plot_no:, association:, client: nil, config: nil)
      cfg    = config || config_for(client)
      params = [owner_name, amount, plot_no, association].map { |v| { type: 'text', text: v.to_s } }
      deliver(
        to: to, type: 'template', client: client, config: cfg,
        payload: { template: {
          name: cfg['reminder_template'],
          language: { code: cfg['reminder_lang'] },
          components: [{ type: 'body', parameters: params }]
        } }
      )
    end
  end
end
