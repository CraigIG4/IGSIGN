# frozen_string_literal: true

# Auto-seed on first boot in production.
# Runs after the app is fully initialised (config.after_initialize) so the DB
# connection pool is ready. Exits immediately once the admin user exists.
# Can never crash the boot process — all errors are caught and logged.
#
# Race condition note: if two processes boot simultaneously both may enter the
# block. seeds.rb uses find_or_initialize_by, and the unique index on users.email
# ensures only one INSERT succeeds. The loser raises RecordNotUnique, which is
# caught below and logged.

if Rails.env.production?
  Rails.application.config.after_initialize do
    begin
      next unless ActiveRecord::Base.connection.table_exists?('users')
      next if User.exists?(email: 'craig@ignitiongroup.co.za')
      load Rails.root.join('db/seeds.rb')
      Rails.logger.info('[AutoSeed] Seed completed successfully')
    rescue => e
      Rails.logger.error("[AutoSeed] Seed failed — app continuing anyway: #{e.message}")
    end
  end
end
