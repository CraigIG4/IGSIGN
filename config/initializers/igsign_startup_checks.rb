# frozen_string_literal: true

# IGSIGN — production startup checks.
# Fail fast on missing security-critical environment variables so a
# misconfigured deploy surfaces immediately rather than silently accepting
# unauthenticated webhook traffic or starting with an insecure configuration.
Rails.application.config.after_initialize do
  next unless Rails.env.production?

  missing = []

  missing << 'INTERNAL_WEBHOOK_SECRET' if ENV['INTERNAL_WEBHOOK_SECRET'].blank?

  # SECRET_KEY_BASE drives cookie signing and encrypted sessions.
  # Rails also reads this from credentials, but an explicit ENV var is required
  # for container deployments where credentials files are not present.
  missing << 'SECRET_KEY_BASE' if ENV['SECRET_KEY_BASE'].blank? && !Rails.application.credentials.secret_key_base

  # REDIS_URL must point to a running Redis instance (used by Sidekiq and the
  # signing-endpoint throttle middleware).
  missing << 'REDIS_URL' if ENV['REDIS_URL'].blank?

  if missing.any?
    raise "IGSIGN startup check failed: the following environment variables are " \
          "required in production but are not set: #{missing.join(', ')}. " \
          "See README § Deployment for required env vars."
  end
end
