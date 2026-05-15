# frozen_string_literal: true

FactoryBot.define do
  factory :igsign_template_metadata do
    association :template
    association :owner, factory: :user
    kind    { 'nda' }
    version { 1 }
    status  { 'active' }
    notes   { nil }

    trait :draft do
      status { 'draft' }
    end

    trait :deprecated do
      status { 'deprecated' }
    end

    trait :no_owner do
      owner { nil }
    end
  end
end
