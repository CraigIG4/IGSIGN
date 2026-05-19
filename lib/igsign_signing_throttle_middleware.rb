# frozen_string_literal: true

# IGSIGN — IP-based rate limiter for public-facing signing endpoints.
#
# Protects against brute-force and enumeration attacks on magic-link URLs.
# Uses a sliding-window counter stored in Redis (Sidekiq's pool) with a TTL
# equal to the window so keys expire automatically.
#
# Throttled paths:
#   /s/*  — SubmitFormController (counterparty signing)
#   /d/*  — StartFormController  (first submitter)
#
# Limits:
#   LIMIT requests per WINDOW seconds per source IP.
#   Failures (Redis unavailable, etc.) are logged and traffic is passed through
#   — we never block legitimate users due to a Redis hiccup.
class IgsignSigningThrottleMiddleware
  THROTTLED_PREFIXES = %w[/s/ /d/].freeze
  LIMIT  = 120  # requests per window
  WINDOW = 3600 # 1 hour in seconds

  def initialize(app)
    @app = app
  end

  def call(env)
    return @app.call(env) unless throttle?(env['PATH_INFO'])

    ip  = extract_ip(env)
    key = "igsign:throttle:signing:#{ip}:#{Time.now.utc.strftime('%Y%m%d%H')}"

    count = increment_counter(key)

    if count && count > LIMIT
      Rails.logger.warn("[IgsignSigningThrottle] rate limit hit for IP=#{ip} path=#{env['PATH_INFO']}")
      return throttle_response
    end

    @app.call(env)
  end

  private

  def throttle?(path)
    THROTTLED_PREFIXES.any? { |prefix| path.start_with?(prefix) }
  end

  # Returns the new counter value, or nil if Redis is unavailable.
  def increment_counter(key)
    Sidekiq.redis do |conn|
      count = conn.call('INCR', key).to_i
      conn.call('EXPIRE', key, WINDOW) if count == 1
      count
    end
  rescue StandardError => e
    Rails.logger.error("[IgsignSigningThrottle] Redis error, passing through: #{e.message.truncate(120)}")
    nil
  end

  # Prefer X-Forwarded-For (set by the load balancer), fall back to REMOTE_ADDR.
  # NormalizeClientIpMiddleware runs before us and has already normalised the header.
  def extract_ip(env)
    forwarded = env['HTTP_X_FORWARDED_FOR'].to_s.split(',').first&.strip
    forwarded.presence || env['REMOTE_ADDR'] || 'unknown'
  end

  def throttle_response
    [
      429,
      {
        'Content-Type'      => 'text/plain',
        'Retry-After'       => WINDOW.to_s,
        'X-RateLimit-Limit' => LIMIT.to_s
      },
      ['Too many requests. Please try again later.']
    ]
  end
end
