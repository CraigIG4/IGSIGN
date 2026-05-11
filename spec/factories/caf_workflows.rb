# frozen_string_literal: true

FactoryBot.define do
  factory :caf_workflow do
    account
    created_by_user { association :user, account: account }
    entity          { 'iti' }
    agreement_type  { 'msa' }
    requestor_name  { 'Test User' }
    requestor_email { Faker::Internet.email }
    counterparty_name  { Faker::Name.name }
    counterparty_email { Faker::Internet.email }
    mandate_description { 'Test mandate' }
  end
end
