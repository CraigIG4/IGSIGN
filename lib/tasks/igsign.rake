# frozen_string_literal: true

# IGSIGN people management rake tasks.

# Allow `rails db:seed:igsign_registry` to run just the registry seed.
namespace :db do
  namespace :seed do
    desc 'Seed only the IGSIGN signatory registry (entities + people)'
    task igsign_registry: :environment do
      load Rails.root.join('db/seeds/igsign_registry.rb')
    end
  end
end


# All data is database-backed — changes persist without a redeploy.
# The legacy config/ig_signatory_overrides.yml file is no longer used.

namespace :igsign do
  namespace :people do
    desc 'List all people in the IGSIGN signatory registry with their current active status'
    task list: :environment do
      puts format("\n%-30s %-45s %-45s %s", 'Name', 'Email', 'Role Title', 'Active')
      puts '-' * 140
      IgSignatory.ordered.each do |sig|
        status = sig.active? ? 'YES' : 'NO  ← INACTIVE'
        puts format('%-30s %-45s %-45s %s', sig.full_name, sig.email, sig.role_title.to_s, status)
      end
      puts "\nTotal: #{IgSignatory.count} people (#{IgSignatory.active.count} active)\n"
    end

    desc 'Deactivate a person by email — rake "igsign:people:deactivate[email@ignitiongroup.co.za]"'
    task :deactivate, [:email] => :environment do |_, args|
      email = args[:email].to_s.strip
      abort('Usage: rake "igsign:people:deactivate[email@ignitiongroup.co.za]"') if email.blank?

      sig = IgSignatory.find_by(email: email) ||
            IgSignatory.where('lower(email) = ?', email.downcase).first
      abort("No signatory found with email: #{email}\nRun `rake igsign:people:list` to see all.") unless sig

      sig.update!(active: false)
      puts "Deactivated: #{sig.full_name} (#{sig.email})"
      puts 'They will be excluded from all new signing chains immediately.'
    end

    desc 'Reactivate a person by email — rake "igsign:people:reactivate[email@ignitiongroup.co.za]"'
    task :reactivate, [:email] => :environment do |_, args|
      email = args[:email].to_s.strip
      abort('Usage: rake "igsign:people:reactivate[email@ignitiongroup.co.za]"') if email.blank?

      sig = IgSignatory.find_by(email: email) ||
            IgSignatory.where('lower(email) = ?', email.downcase).first
      abort("No signatory found with email: #{email}\nRun `rake igsign:people:list` to see all.") unless sig

      sig.update!(active: true)
      puts "Reactivated: #{sig.full_name} (#{sig.email})"
      puts 'They will appear in new signing chains again immediately.'
    end
  end

  desc 'Pre-deploy smoke check — verifies env vars, registry, templates and connectivity'
  task smoke_test: :environment do
    require 'sidekiq/api'

    results = []
    failures = []

    def check(label, &blk)
      value = blk.call
      if value
        puts "  [PASS] #{label}"
        { label:, pass: true }
      else
        puts "  [FAIL] #{label}"
        { label:, pass: false }
      end
    rescue StandardError => e
      puts "  [FAIL] #{label} — #{e.message}"
      { label:, pass: false, error: e.message }
    end

    puts "\n#{'─' * 60}"
    puts '  IGSIGN Smoke Test'
    puts "  #{Time.current.strftime('%Y-%m-%d %H:%M %Z')}"
    puts "#{'─' * 60}\n"

    puts "\n[1] Environment variables"
    results << check('INTERNAL_WEBHOOK_SECRET is set') { ENV['INTERNAL_WEBHOOK_SECRET'].present? }
    results << check('SMTP_ADDRESS / RESEND is configured') do
      ENV['SMTP_ADDRESS'].present? || ENV['RESEND_API_KEY'].present? || ENV['SMTP_HOST'].present?
    end
    results << check('SECRET_KEY_BASE is set') { ENV['SECRET_KEY_BASE'].present? }
    results << check('DATABASE_URL is set') { ENV['DATABASE_URL'].present? }
    results << check('AI_API_KEY is set (optional — contract parsing)') do
      ENV['AI_API_KEY'].present?
    end

    puts "\n[2] Database connectivity"
    results << check('PostgreSQL connection') { ActiveRecord::Base.connection.active? }

    puts "\n[3] Signatory registry"
    entity_keys = %w[iti comit mvnx spot_connect ignition_digital ignition_cx_us ifs gumtree spot_money]
    results << check("All 9 entities seeded (#{IgEntity.count} found)") { IgEntity.count >= 9 }
    entity_keys.each do |key|
      results << check("Entity '#{key}' exists") { IgEntity.exists?(key: key) }
    end
    results << check("IgSignatories seeded (#{IgSignatory.count} found)") { IgSignatory.count >= 15 }
    results << check('No hallucinated names (Megan Venter, Valde Ferradaz, Greg Goosen, John Hawthorne)') do
      bad = %w[Megan\ Venter Valde\ Ferradaz Greg\ Goosen John\ Hawthorne]
      bad.none? { |name| IgSignatory.exists?(['full_name ILIKE ?', "%#{name}%"]) }
    end

    puts "\n[4] Templates"
    results << check('IGSIGN CAF Template exists') do
      Template.joins(:account).exists?(name: 'IGSIGN CAF Template')
    end
    caf_tpl = Template.find_by(name: 'IGSIGN CAF Template')
    results << check('CAF Template has submitters configured') do
      caf_tpl.present? && Array(caf_tpl.submitters).any?
    end

    puts "\n[5] Approval matrices"
    results << check('At least one active CafApprovalMatrix exists') do
      CafApprovalMatrix.active.any?
    end

    puts "\n[6] Redis / Sidekiq"
    results << check('Redis connection (Sidekiq)') do
      Sidekiq.redis { |c| c.ping; true }
    end

    puts "\n[7] Signing chain resolution"
    results << check("ITI NDA chain resolves (Craig Lawrence)") do
      chain = IgSignatories.chain_for('iti', 'nda')
      Array(chain[:stage0]).any? { |s| s[:email].to_s.downcase.include?('clawre') }
    end
    results << check("ITI MSA group signer is Sean or Don Bergsma") do
      chain = IgSignatories.chain_for('iti', 'long_form')
      emails = Array(chain[:stage1]).map { |s| s[:email].to_s.downcase }
      emails.any? { |e| e.include?('sean') || e.include?('donovan') }
    end

    failures = results.reject { |r| r[:pass] }
    optional_failures = failures.select { |r| r[:label].include?('optional') }
    blocking_failures = failures.reject { |r| r[:label].include?('optional') }

    puts "\n#{'─' * 60}"
    puts "  RESULT: #{results.count { |r| r[:pass] }}/#{results.count} checks passed"
    if blocking_failures.any?
      puts "  STATUS: BLOCKED — #{blocking_failures.count} blocking failure(s):\n"
      blocking_failures.each { |r| puts "    ✗ #{r[:label]}" }
    elsif optional_failures.any?
      puts "  STATUS: PROCEED WITH CAVEATS — #{optional_failures.count} optional check(s) failed:\n"
      optional_failures.each { |r| puts "    ! #{r[:label]}" }
    else
      puts '  STATUS: ALL CHECKS PASSED — system is pilot-ready'
    end
    puts "#{'─' * 60}\n"

    exit(1) if blocking_failures.any?
  end

  desc 'List all IGSIGN entities in the registry'
  task entities: :environment do
    puts format("\n%-20s %-55s %-20s %s", 'Key', 'Name', 'Display Name', 'Active')
    puts '-' * 110
    IgEntity.order(:key).each do |e|
      status = e.active? ? 'YES' : 'NO'
      puts format('%-20s %-55s %-20s %s', e.key, e.name, e.display_name.to_s, status)
    end
    puts "\nTotal: #{IgEntity.count} entities\n"
  end
end
