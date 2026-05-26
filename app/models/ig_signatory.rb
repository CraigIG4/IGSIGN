# frozen_string_literal: true

# A real person authorised to sign agreements on behalf of an Ignition Group entity.
# Source of truth: db/seeds/igsign_registry.rb — do not add people here directly.
# To deactivate someone, set active: false (via the /legal_ops/signatories admin UI).
class IgSignatory < ApplicationRecord
  SENIORITY_LEVELS = %w[Executive Senior\ Manager].freeze
  POSITIONS = %w[
    bu_head bu_cfo bu_cfo_alternate group_clo group_cfo group_ceo group_coo
    group_signer group_signer_alt approver_only procurement
  ].freeze

  has_many :ig_entity_signatories, dependent: :destroy
  has_many :ig_entities, through: :ig_entity_signatories

  validates :full_name, presence: true
  validates :email,     presence: true, uniqueness: { case_sensitive: false },
                        format: { with: URI::MailTo::EMAIL_REGEXP }
  validates :seniority, inclusion: { in: SENIORITY_LEVELS }, allow_blank: true

  scope :active, -> { where(active: true) }
  scope :ordered, -> { order(:full_name) }

  # Returns a hash in the shape callers of the old IgSignatories::PEOPLE hash expect:
  # { name:, title:, email:, key: }
  def to_legacy_hash
    {
      key:   email.split('@').first.downcase.tr('.', '_').to_sym,
      name:  full_name,
      title: role_title.to_s,
      email: email
    }
  end
end
