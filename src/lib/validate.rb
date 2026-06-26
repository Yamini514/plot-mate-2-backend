module App
  # Shared, server-side field validators. Every method returns an error message
  # String when the value is invalid, or nil when it passes — so callers compose
  # a {field => message_or_nil} map and hand it to Base#validate!, which halts
  # with the compacted, field-keyed errors. The rules mirror the frontend
  # lib/validate.js so client and server agree (client = UX, server = the gate).
  #
  #   validate!(
  #     'title'   => App::Validate.text(params[:title], max: 160),
  #     'email'   => App::Validate.email(params[:email]),
  #     'end_at'  => App::Validate.date_range(params[:start_at], params[:end_at]),
  #   )
  module Validate
    module_function

    EMAIL_RE = /\A[^@\s]+@[^@\s]+\.[^@\s]+\z/
    PHONE_RE = /\A\d{10}\z/
    SPECIAL_RE = /[^A-Za-z0-9]/
    ALLOWED_UPLOAD_EXT = %w[pdf jpg jpeg png].freeze

    # Treats nil, empty, and whitespace-only as blank.
    def blank?(v)
      v.nil? || (v.respond_to?(:strip) ? v.to_s.strip.empty? : (v.respond_to?(:empty?) && v.empty?))
    end

    def presence(v, label: 'This field')
      blank?(v) ? "#{label} is required" : nil
    end

    def text(v, min: nil, max: nil, label: 'This field', required: true)
      return required ? "#{label} is required" : nil if blank?(v)
      s = v.to_s.strip
      return "Must be at least #{min} characters" if min && s.length < min
      return "Must be at most #{max} characters"  if max && s.length > max
      nil
    end

    def email(v, required: true)
      return required ? 'Email is required' : nil if blank?(v)
      v.to_s.strip.match?(EMAIL_RE) ? nil : 'Enter a valid email address'
    end

    def phone(v, required: false)
      return required ? 'Phone is required' : nil if blank?(v)
      v.to_s.strip.match?(PHONE_RE) ? nil : 'Must be a 10-digit number'
    end

    # 8+ chars with an upper, lower, number and special character.
    def password(v)
      s = v.to_s
      return 'Password is required' if s.strip.empty?
      missing = []
      missing << '8+ characters'        if s.length < 8
      missing << 'an uppercase letter'  unless s.match?(/[A-Z]/)
      missing << 'a lowercase letter'   unless s.match?(/[a-z]/)
      missing << 'a number'             unless s.match?(/\d/)
      missing << 'a special character'  unless s.match?(SPECIAL_RE)
      missing.empty? ? nil : "Password must contain #{missing.join(', ')}"
    end

    def number(v, min: nil, max: nil, positive: false, integer: false, required: true, label: 'This field')
      return required ? "#{label} is required" : nil if blank?(v)
      n = integer ? Integer(v.to_s, exception: false) : Float(v.to_s, exception: false)
      return 'Must be a number' if n.nil?
      return 'Must be greater than zero' if positive && n <= 0
      return "Must be at least #{min}" if min && n < min
      return "Must be at most #{max}"  if max && n > max
      nil
    end

    # End must be strictly after start (only checked when both are present/parseable).
    def date_range(start_at, end_at)
      return nil if blank?(start_at) || blank?(end_at)
      s = parse_time(start_at)
      e = parse_time(end_at)
      return nil if s.nil? || e.nil?
      e > s ? nil : 'End date must be after the start date'
    end

    def future(v, label: 'Date')
      return nil if blank?(v)
      t = parse_time(v)
      return nil if t.nil?
      t >= Time.now ? nil : "#{label} cannot be in the past"
    end

    def file(name:, size: nil, allowed: ALLOWED_UPLOAD_EXT, max_bytes: 10 * 1024 * 1024)
      return 'A file is required' if blank?(name)
      ext = File.extname(name.to_s).delete('.').downcase
      return "Only #{allowed.map(&:upcase).join(', ')} files are allowed" unless allowed.include?(ext)
      return "File must be under #{max_bytes / (1024 * 1024)}MB" if size && size.to_i > max_bytes
      nil
    end

    # Drop the nil (passing) entries, leaving only real errors.
    def collect(checks)
      checks.reject { |_, msg| msg.nil? }
    end

    def parse_time(v)
      return v if v.is_a?(Time)
      Time.parse(v.to_s)
    rescue ArgumentError, TypeError
      nil
    end
  end
end
