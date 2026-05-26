# frozen_string_literal: true

FactoryBot.define do
  factory :ig_entity do
    sequence(:key)  { |n| "entity_#{n}" }
    sequence(:name) { |n| "Test Entity #{n} (Pty) Ltd" }
    display_name    { name.split.first(2).join(' ') }
    active          { true }

    trait :iti do
      key          { 'iti' }
      name         { 'Ignition Telecoms Investments (Pty) Ltd' }
      display_name { 'ITI' }
    end

    trait :comit do
      key          { 'comit' }
      name         { 'Comit Technologies (Pty) Ltd' }
      display_name { 'Comit' }
    end
  end
end
