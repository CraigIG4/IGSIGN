# frozen_string_literal: true

# == Schema Information
#
# Table name: companies
#
#  id                    :bigint           not null, primary key
#  address               :text
#  agreements_count      :integer          default(0), not null
#  country               :string           default("ZA"), not null
#  domain                :string
#  name                  :string           not null
#  primary_contact_email :string
#  primary_contact_name  :string
#  registration_number   :string
#  created_at            :datetime         not null
#  updated_at            :datetime         not null
#  account_id            :bigint           not null
#
# Indexes
#
#  index_companies_on_account_id             (account_id)
#  index_companies_on_account_id_and_domain  (account_id,domain)
#  index_companies_on_account_id_and_name    (account_id,name)
#
# Foreign Keys
#
#  fk_rails_...  (account_id => accounts.id)
#
class Company < ApplicationRecord
  belongs_to :account
  has_many :caf_workflows, dependent: :nullify

  validates :name, presence: true
  validates :primary_contact_email,
            format: { with: URI::MailTo::EMAIL_REGEXP },
            allow_blank: true

  scope :alphabetical, -> { order(name: :asc) }
  scope :search, lambda { |q|
    term = "%#{q.to_s.downcase.strip}%"
    where(
      'lower(name) LIKE ? OR lower(domain) LIKE ? OR lower(primary_contact_name) LIKE ?',
      term, term, term
    )
  }

  def display_name
    domain.present? ? "#{name} (#{domain})" : name
  end

  def sync_agreements_count!
    update_column(:agreements_count, caf_workflows.count) # rubocop:disable Rails/SkipsModelValidations
  end
end
