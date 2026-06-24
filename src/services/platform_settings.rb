class App::Services::PlatformSettings < App::Services::Base
  # Singleton platform-wide config. The row is created lazily (not seeded in the
  # migration, which runs without pg_json). `show` returns the effective config
  # (defaults deep-merged); `update` persists the edited sections.
  def model = PlatformSetting

  def show = return_success(row.effective)

  # The frontend sends the full settings object; we replace the stored value
  # with it (already validated client-side against the known sections). Unknown
  # sections are ignored on read via PlatformSetting#effective.
  def update
    incoming = params[:settings]
    return_errors!('settings object required', 422) unless incoming.is_a?(Hash)
    r0 = row
    r0.set(settings: (r0.settings || {}).merge(incoming), updated_by: App.cu.id)
    save(r0) do
      App::Audit.record('settings.update', entity: r0,
                        summary: 'Updated platform settings', meta: { sections: incoming.keys })
      return_success(r0.effective)
    end
  end

  # Send a probe email using the platform's configured From address, so the
  # super admin can confirm SMTP before relying on approval/notification mails.
  def test_email
    to = params[:to].to_s.strip
    return_errors!('A recipient email is required', 422) if to.empty?
    cfg = row.effective['email'] || {}
    App::Mailer.deliver(
      to: to,
      subject: 'PlotMate platform email test',
      html_body: "<p>This is a test email from #{cfg['from_name'] || 'PlotMate'}. " \
                 'If you received it, platform email is configured correctly.</p>',
      client: nil
    )
    return_success("Test email sent to #{to}")
  rescue => e
    App.logger.error("Platform test_email failed: #{e.message}")
    return_errors!("Couldn't send the test email: #{e.message}", 422)
  end

  private

  # Find-or-create the single settings row (id is whatever the table assigns).
  def row
    @row ||= (PlatformSetting.order(:id).first || PlatformSetting.create(settings: {}))
  end
end
