class App::Services::SystemHealth < App::Services::Base
  # Operational status snapshot for the super-admin System Health page. Every
  # probe is best-effort and self-contained: a single failing check reports its
  # own 'down'/'unknown' status rather than failing the whole response.
  def overview
    return_success(
      database: db_health,
      api:      api_health,
      email:    email_health,
      storage:  storage_health,
      jobs:     jobs_health,
      checked_at: Time.now
    )
  end

  private

  def monotonic = Process.clock_gettime(Process::CLOCK_MONOTONIC)

  def db_health
    started = monotonic
    App.db.fetch('SELECT 1 AS ok').first
    latency = ((monotonic - started) * 1000).round(1)
    pool = App.db.pool
    { status: 'healthy', latency_ms: latency,
      connections: (pool.respond_to?(:size) ? pool.size : nil),
      max_connections: (pool.respond_to?(:max_size) ? pool.max_size : nil) }
  rescue => e
    { status: 'down', error: e.message }
  end

  # A second cheap round-trip stands in for an API liveness probe + response time.
  def api_health
    started = monotonic
    User.where(id: 0).count
    { status: 'operational', response_time_ms: ((monotonic - started) * 1000).round(1) }
  rescue => e
    { status: 'degraded', error: e.message }
  end

  def email_health
    cfg = platform_email
    configured = cfg['from_email'].to_s.strip != '' && cfg['smtp_host'].to_s.strip != ''
    { status: configured ? 'configured' : 'not_configured',
      from_email: cfg['from_email'], smtp_host: cfg['smtp_host'] }
  end

  def storage_health
    if s3_configured?
      { status: 'configured', provider: 'Amazon S3',
        bucket: ENV['AWS_S3_BUCKET'], region: ENV['AWS_REGION'] || 'us-east-1' }
    else
      { status: 'not_configured', provider: 'Inline / data-URL fallback' }
    end
  end

  # Background work proxied by the reminder queue: pending (scheduled), delivered
  # (sent) and overdue (scheduled but past due — a sign the scheduler isn't running).
  def jobs_health
    return { status: 'unknown' } unless App::Models.const_defined?(:Reminder)
    by_status = Reminder.group_and_count(:status).all
                        .each_with_object(Hash.new(0)) { |r, h| h[r[:status]] = r[:count] }
    overdue = Reminder.where(status: 'scheduled').where { scheduled_for < Time.now }.count
    { status: overdue.zero? ? 'ok' : 'attention',
      scheduled: by_status['scheduled'], sent: by_status['sent'], overdue: overdue }
  rescue => e
    { status: 'unknown', error: e.message }
  end

  def platform_email
    return {} unless App::Models.const_defined?(:PlatformSetting)
    row = PlatformSetting.order(:id).first
    (row&.effective || {})['email'] || {}
  rescue
    {}
  end
end
