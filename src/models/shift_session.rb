# Guard shift / attendance sessions.
#
# Sequel resolves a model's schema at class-definition time, so if the
# `shift_sessions` table hasn't been migrated yet, naively subclassing
# Sequel::Model here would raise and take down the *entire* API at boot. We
# guard the definition on the table existing: until `rake db:migrate` runs,
# the constant simply isn't defined and shift tracking stays dormant (every
# caller checks `App::Models.const_defined?(:ShiftSession)` first), instead of
# crashing logins, the gate and every other endpoint.
if App.db.table_exists?(:shift_sessions)
  class App::Models::ShiftSession < Sequel::Model
    # Standard gate shifts. The shift covering a given time is derived from the
    # wall clock — the same three windows the guard profile shows — so we never
    # need a per-guard roster to know when a shift "should" end.
    SHIFTS = [
      { name: 'Morning', from: 6,  to: 14 },
      { name: 'Evening', from: 14, to: 22 },
      { name: 'Night',   from: 22, to: 6  }
    ].freeze

    def self.shift_for(time)
      h = time.hour
      SHIFTS.find { |s| s[:from] < s[:to] ? (h >= s[:from] && h < s[:to]) : (h >= s[:from] || h < s[:to]) } || SHIFTS[0]
    end

    # The wall-clock instant the shift covering `time` is scheduled to end. The
    # night shift rolls over midnight, so its end is the next morning.
    def self.scheduled_end_for(time)
      s = shift_for(time)
      base = Time.new(time.year, time.month, time.day, s[:to], 0, 0, time.utc_offset)
      base += 24 * 60 * 60 if s[:to] <= s[:from] # night shift ends the next day
      base
    end

    def active? = ended_at.nil?

    # Minutes on duty (running for an active shift, fixed once ended).
    def duration_mins
      return nil unless started_at
      (((ended_at || Time.now) - started_at) / 60.0).round
    end

    def as_pos
      {
        id: id,
        user_id: user_id,
        shift_name: shift_name,
        started_at: started_at,
        ended_at: ended_at,
        scheduled_end: scheduled_end,
        ended_early: ended_early,
        end_reason: end_reason,
        duration_mins: duration_mins,
        active: active?
      }
    end
  end
else
  App.logger.warn('[shift_sessions] table not found — run `rake db:migrate`. Guard shift tracking is paused until the migration runs.')
end
