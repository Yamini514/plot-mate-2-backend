require 'time' # Time.parse fallback in month_key

class App::Services::Analytics < App::Services::Base
  # Platform reporting. All series are single grouped queries (no per-row loads).
  # Not tenant-scoped — counts span every venture.

  # Dashboard sparkline payload: last-6-month per-period counts for the headline
  # widgets, computed in three grouped queries.
  def trends
    return_success(
      ventures:      monthly_counts(Client, 6),
      users:         monthly_counts(User.exclude(role: User::ROLES[:super_admin]), 6),
      registrations: monthly_counts(OnboardingRequest, 6)
    )
  end

  def venture_growth
    series = monthly_counts(Client, months)
    return_success(period: series, cumulative: cumulate(series), total: Client.count)
  end

  def user_growth
    base = User.exclude(role: User::ROLES[:super_admin])
    series = monthly_counts(base, months)
    return_success(period: series, cumulative: cumulate(series), total: base.count)
  end

  def registration_trends
    by_status = OnboardingRequest.group_and_count(:status).all
                                 .each_with_object({}) { |r, h| h[r[:status]] = r[:count] }
    return_success(period: monthly_counts(OnboardingRequest, months), by_status: by_status,
                   total: OnboardingRequest.count)
  end

  def active_ventures
    return_success(
      active:    Client.where(active: true).count,
      suspended: Client.where(active: false).count,
      by_status: Client.group_and_count(:status).all
                       .each_with_object({}) { |r, h| h[r[:status] || 'active'] = r[:count] }
    )
  end

  # Future-ready: platform revenue rolls up per-venture billing once that lands.
  # Returns a stable shape now so the frontend needs no change later.
  def revenue
    return_success(available: false,
                   message: 'Revenue reporting activates once platform billing is enabled.',
                   period: [], total_paise: 0, currency: 'INR')
  end

  # CSV export of the requested report (?report=venture-growth|user-growth|registrations).
  def export
    series = case qs[:report]
             when 'user-growth'   then monthly_counts(User.exclude(role: User::ROLES[:super_admin]), months)
             when 'registrations' then monthly_counts(OnboardingRequest, months)
             else monthly_counts(Client, months)
             end
    csv  = "month,count\n" + series.map { |p| "#{p[:month]},#{p[:count]}" }.join("\n") + "\n"
    name = qs[:report] || 'venture-growth'
    # 3-arg halt (status, headers, body) — same form routes.rb uses — so the CSV
    # body and its headers replace the route's default JSON content type.
    r.halt(200, { 'Content-Type' => 'text/csv',
                  'Content-Disposition' => %(attachment; filename="#{name}.csv") }, csv)
  end

  private

  def months = [[(qs[:months] || 12).to_i, 1].max, 36].min

  # Per-month counts for the last `n` months, gap-filled to a contiguous series
  # so the chart has no missing buckets. Buckets keyed by 'YYYY-MM'. The grouped
  # expression is aliased (:bucket) so we never depend on Sequel's derived
  # column name for a function call.
  def monthly_counts(ds, n)
    bucket = Sequel.function(:date_trunc, 'month', :created_at)
    cutoff = Time.now - (n * 31 * 24 * 3600)
    raw = ds.where { created_at >= cutoff }
            .group(bucket)
            .select(bucket.as(:bucket), Sequel.function(:count, :id).as(:n))
            .all
            .each_with_object({}) { |row, h| h[month_key(row[:bucket])] = row[:n] }

    buckets(n).map { |k| { month: k, count: raw[k] || 0 } }
  end

  def buckets(n)
    now = Time.now
    (0...n).to_a.reverse.map do |i|
      m = now.month - i
      y = now.year
      while m <= 0
        m += 12
        y -= 1
      end
      format('%04d-%02d', y, m)
    end
  end

  def month_key(t)
    t = Time.parse(t.to_s) unless t.respond_to?(:year)
    format('%04d-%02d', t.year, t.month)
  end

  def cumulate(series)
    running = 0
    series.map { |p| running += p[:count]; { month: p[:month], count: running } }
  end
end
