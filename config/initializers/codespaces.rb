# IGSIGN: GitHub Codespaces dev preview compatibility (DEV ENV ONLY)
# The Codespace tunnel rewrites Host headers, breaking CSRF Origin checks.
# This bypass is gated to ENV['CODESPACES'] which is only set inside a Codespace.
# Production is unaffected and retains full forgery protection.
if ENV['CODESPACES'] && Rails.env.development?
  Rails.application.config.to_prepare do
    ApplicationController.skip_forgery_protection raise: false
  end
end
