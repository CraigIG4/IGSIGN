# frozen_string_literal: true

# IGSIGN people management rake tasks.
# These tasks modify config/ig_signatory_overrides.yml.
# Commit the file after running so the change survives redeploys.

namespace :igsign do
  namespace :people do
    desc 'List all people in the IgSignatories registry with their current active status'
    task list: :environment do
      overrides = IgSignatories.overrides
      puts format("\n%-20s %-35s %-45s %s", 'Key', 'Name', 'Email', 'Active') # rubocop:disable Style/RedundantFormat
      puts '-' * 110
      IgSignatories::PEOPLE.each do |key, p|
        override = overrides.dig(key.to_s, 'active')
        active = override.nil? ? p[:active] : override
        status = active ? 'YES' : 'NO  ← INACTIVE'
        puts format('%-20s %-35s %-45s %s', key, p[:name], p[:email], status)
      end
      puts
    end

    desc 'Deactivate a person by email — rake "igsign:people:deactivate[email@ignitiongroup.co.za]"'
    task :deactivate, [:email] => :environment do |_, args|
      email = args[:email].to_s.strip
      abort('Usage: rake "igsign:people:deactivate[email@ignitiongroup.co.za]"') if email.blank?

      person_key, person = IgSignatories::PEOPLE.find { |_, p| p[:email].casecmp?(email) }
      abort("No person found with email: #{email}\nRun `rake igsign:people:list` to see all people.") unless person_key

      write_override(person_key.to_s, 'active', false)

      puts "Deactivated: #{person[:name]} (#{person[:email]})"
      puts 'They will be excluded from all new signing chains.'
      puts 'Commit config/ig_signatory_overrides.yml and push to preserve across redeploys.'
    end

    desc 'Reactivate a person by email — rake "igsign:people:reactivate[email@ignitiongroup.co.za]"'
    task :reactivate, [:email] => :environment do |_, args|
      email = args[:email].to_s.strip
      abort('Usage: rake "igsign:people:reactivate[email@ignitiongroup.co.za]"') if email.blank?

      person_key, person = IgSignatories::PEOPLE.find { |_, p| p[:email].casecmp?(email) }
      abort("No person found with email: #{email}\nRun `rake igsign:people:list` to see all people.") unless person_key

      write_override(person_key.to_s, 'active', true)

      puts "Reactivated: #{person[:name]} (#{person[:email]})"
      puts 'They will appear in new signing chains again.'
      puts 'Commit config/ig_signatory_overrides.yml and push to preserve across redeploys.'
    end
  end
end

def write_override(person_key, field, value)
  require 'yaml'
  file = Rails.root.join('config/ig_signatory_overrides.yml')
  data = File.exist?(file) ? (YAML.safe_load_file(file) || {}) : {}
  data[person_key] ||= {}
  data[person_key][field] = value

  # Preserve the header comment then write the data
  header = <<~HEADER
    # IGSIGN — IG Signatory Overrides
    # Overrides active status for people in IgSignatories::PEOPLE.
    # Takes precedence over the :active field in the constant.
    # Changes take effect on next application restart.
    # Commit this file so changes survive redeploys.
    #
  HEADER

  File.write(file, header + data.to_yaml.delete_prefix("---\n"))
end
