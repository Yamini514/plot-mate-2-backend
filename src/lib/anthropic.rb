# Anthropic (Claude) vision client. Reads the plot numbers off an uploaded
# site-plan image so the admin doesn't have to transcribe them by hand. Mirrors
# App::WhatsApp's house style: plain Net::HTTP, raise-on-failure so the caller
# can surface a precise error, ENV-driven config. Owns the prompt, JSON parsing,
# image decoding and the dev mock.
require 'net/http'
require 'uri'
require 'json'
require 'base64'

module App
  module Anthropic
    module_function

    API_HOST      = 'api.anthropic.com'
    API_VERSION   = '2023-06-01'
    DEFAULT_MODEL = 'claude-sonnet-4-6'
    MAX_TOKENS    = 4096

    PROMPT = <<~TXT
      You are reading a real-estate plotting / layout site plan image. Extract
      EVERY plot number printed inside a plot block. Group the numbers by the
      phase or section heading they belong to (e.g. "PHASE-1", "PHASE-2"). If no
      phase heading applies to some blocks, group them under "Unphased".

      Rules:
      - Return each plot number exactly as printed, INCLUDING leading zeros
        (e.g. "01", "08").
      - List each DISTINCT plot number only once, even if it appears more than
        once on the plan.
      - Roads, parks, open spaces, the legend/area-statement tables, the compass
        and the title block are NOT plots — ignore them.
      - Do not invent numbers you cannot actually read.

      Respond with ONLY a JSON object, no prose, in exactly this shape:
      {"phases":[{"phase":"Phase 2","numbers":["1","2","3"]}]}
    TXT

    def api_key
      ENV['ANTHROPIC_API_KEY'].to_s
    end

    def configured?
      !api_key.strip.empty?
    end

    def model
      ENV['ANTHROPIC_MODEL'].to_s.strip.empty? ? DEFAULT_MODEL : ENV['ANTHROPIC_MODEL']
    end

    def truthy?(v)
      %w[1 true yes].include?(v.to_s.strip.downcase)
    end

    # Sample data instead of a real call — on when ANTHROPIC_MOCK is truthy, or
    # automatically in development when no key is set yet. A real key disables it.
    def mock_enabled?
      return true if truthy?(ENV['ANTHROPIC_MOCK'])
      !configured? && ENV['RACK_ENV'].to_s == 'development'
    end

    # Extract plot numbers grouped by phase from a site-plan image. Returns a
    # parsed hash: { "phases" => [ { "phase" => …, "numbers" => […] }, … ] }.
    def detect_plots(image_data: nil, image_url: nil)
      return mock_result if mock_enabled?
      raise 'AI vision is not configured. Set ANTHROPIC_API_KEY on the server.' unless configured?

      media_type, b64 = image_source(image_data: image_data, image_url: image_url)
      raw = call(media_type: media_type, b64: b64, prompt: PROMPT)
      parse_json(raw)
    end

    # Low-level Messages call: one image + prompt, returns the concatenated text.
    def call(media_type:, b64:, prompt:)
      uri  = URI("https://#{API_HOST}/v1/messages")
      body = {
        model: model, max_tokens: MAX_TOKENS,
        messages: [{ role: 'user', content: [
          { type: 'image', source: { type: 'base64', media_type: media_type, data: b64 } },
          { type: 'text', text: prompt }
        ] }]
      }

      http = Net::HTTP.new(uri.host, uri.port)
      http.use_ssl      = true
      http.open_timeout = 15
      http.read_timeout = 90

      req = Net::HTTP::Post.new(uri)
      req['x-api-key']         = api_key
      req['anthropic-version'] = API_VERSION
      req['content-type']      = 'application/json'
      req.body = body.to_json

      res    = http.request(req)
      parsed = (JSON.parse(res.body) rescue {})
      unless res.is_a?(Net::HTTPSuccess)
        detail = parsed.dig('error', 'message') || res.body.to_s
        raise "Anthropic API error (#{res.code}): #{detail}"
      end
      Array(parsed['content']).map { |b| b['text'] }.compact.join
    end

    # ---- shared helpers ------------------------------------------------------

    # Split a data URL ("data:image/jpeg;base64,AAAA…") into [media_type, base64].
    def parse_data_url(data_url)
      m = data_url.to_s.match(%r{\Adata:(image/[a-zA-Z0-9.+-]+);base64,(.+)\z}m)
      m && [m[1], m[2]]
    end

    # Fetch a hosted image and return [media_type, base64] (S3-hosted layouts).
    def fetch_image(url)
      uri = URI(url)
      res = Net::HTTP.get_response(uri)
      raise "Could not fetch the layout image (#{res.code})" unless res.is_a?(Net::HTTPSuccess)
      media = res['content-type'].to_s.split(';').first
      media = 'image/jpeg' if media.to_s.empty?
      [media, Base64.strict_encode64(res.body)]
    end

    # Resolve (data URL | http URL) into the [media_type, base64] pair the API expects.
    def image_source(image_data: nil, image_url: nil)
      if (pair = parse_data_url(image_data))
        pair
      elsif !image_url.to_s.strip.empty?
        fetch_image(image_url)
      else
        raise 'No layout image to scan.'
      end
    end

    # Pull the JSON object out of the model's reply, tolerating ```json fences.
    def parse_json(raw)
      text = raw.to_s.strip
      text = text.sub(/\A```(?:json)?/, '').sub(/```\z/, '').strip if text.start_with?('```')
      start  = text.index('{')
      finish = text.rindex('}')
      raise 'The AI did not return a readable result. Try again.' if start.nil? || finish.nil?
      JSON.parse(text[start..finish])
    rescue JSON::ParserError
      raise 'The AI returned an unreadable result. Try again.'
    end

    # Representative result (matches the Green City sample plan).
    def mock_result
      {
        'phases' => [
          { 'phase' => 'Phase 2',   'numbers' => (1..134).map(&:to_s) },
          { 'phase' => 'Front Row', 'numbers' => (1..8).map { |n| format('%02d', n) } }
        ]
      }
    end
  end
end
