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
