# frozen_string_literal: true

# IGSIGN seed data.
# Safe to re-run — all operations use find_or_create_by / find_or_initialize_by
# so they are fully idempotent.

# ---------------------------------------------------------------------------
# Account
# ---------------------------------------------------------------------------
account = Account.find_or_initialize_by(name: 'Ignition Group')

if account.new_record?
  account.assign_attributes(
    timezone: 'Johannesburg',   # ActiveSupport::TimeZone name for SAST (UTC+2)
    locale:   'en-US'
  )
  account.save!
  puts "Created account: #{account.name}"
else
  puts "Account already exists: #{account.name}"
end

# ---------------------------------------------------------------------------
# Admin user — Craig Doidge
# ---------------------------------------------------------------------------
user = User.find_or_initialize_by(email: 'craig@ignitiongroup.co.za')

if user.new_record?
  user.assign_attributes(
    first_name:    'Craig',
    last_name:     'Doidge',
    password:      'IgSign2026!',
    role:          User::ADMIN_ROLE,
    account:       account,
    confirmed_at:  Time.current   # skip email confirmation on seed
  )
  user.save!
  puts "Created admin user: #{user.email}"
else
  puts "Admin user already exists: #{user.email}"
end

# ---------------------------------------------------------------------------
# IG Entities and People
# ---------------------------------------------------------------------------
# IgSignatories::ENTITIES and IgSignatories::PEOPLE are Ruby constants defined
# in lib/ig_signatories.rb — they require no database seed.
#
# Deactivation is managed via config/ig_signatory_overrides.yml:
#   bundle exec rake "igsign:people:deactivate[email@ignitiongroup.co.za]"
#
# For v2, these will be migrated to managed DB models (IgPerson, IgEntity).
# See docs/todo/v2-people-management.md
puts 'IG entities/people: managed as Ruby constants (no DB seed required)'
