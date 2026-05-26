# frozen_string_literal: true

FactoryBot.define do
  factory :caf_workflow do
    account
    created_by_user { association :user, account: account }
    entity          { 'iti' }
    agreement_type  { 'msa' }
    caf_type        { 'long_form' }
    requestor_name  { 'Test User' }
    requestor_email { Faker::Internet.email }
    counterparty_name  { Faker::Name.name }
    counterparty_email { Faker::Internet.email }
    mandate_description { 'Test mandate' }

    # Ensure the entity key exists in ig_entities so the inclusion validation passes.
    # Inserts a minimal placeholder record when the full registry hasn't been seeded.
    after(:build) do |workflow|
      IgEntity.find_or_create_by!(key: workflow.entity) do |e|
        e.name   = workflow.entity.to_s.humanize
        e.active = true
      end
    end
  end
end
