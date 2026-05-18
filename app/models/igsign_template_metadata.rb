# frozen_string_literal: true

# IGSIGN metadata layer on top of DocuSeal's Template.
# Tracks kind (agreement type), owner, version, status, and entity scope.
# One record per DocuSeal template; created on first admin interaction.
#
# == Schema Information
#
# Table name: igsign_template_metadata
#
#  id           :bigint           not null, primary key
#  template_id  :bigint           not null
#  owner_id     :bigint
#  kind         :string           not null, default: "short_form_caf"
#  version      :integer          not null, default: 1
#  status       :string           not null, default: "draft"
#  notes        :text
#  entity_scope :jsonb            not null, default: []
#  created_at   :datetime         not null
#  updated_at   :datetime         not null
#
# entity_scope stores an array of IgSignatories entity keys, e.g. ["iti"].
# An empty array means the template is not entity-specific (non-NDA or global).
# NDA templates have exactly one entity key so the same DocuSeal Template PDF
# can be pointed to by 13 separate metadata records (one per IG entity).
#
class IgsignTemplateMetadata < ApplicationRecord
  # Three kinds post-consolidation (Prompt 4).
  # Legacy 8-kind values (msa, sla, vendor, employment, addendum, policy, other)
  # were remapped by migration 20260518000003.
  KINDS = %w[nda short_form_caf long_form_caf].freeze

  STATUSES = %w[draft active deprecated].freeze

  STATUS_LABELS = {
    'draft'         => 'Draft',
    'active'        => 'Active',
    'deprecated'    => 'Deprecated'
  }.freeze

  KIND_LABELS = {
    'nda'           => 'NDA',
    'short_form_caf' => 'Short-form CAF',
    'long_form_caf'  => 'Long-form CAF'
  }.freeze

  belongs_to :template
  belongs_to :owner, class_name: 'User', optional: true

  validates :kind,    presence: true, inclusion: { in: KINDS }
  validates :status,  presence: true, inclusion: { in: STATUSES }
  validates :version, presence: true, numericality: { only_integer: true, greater_than: 0 }

  scope :active,         -> { where(status: 'active') }
  scope :not_deprecated, -> { where.not(status: 'deprecated') }
  scope :by_kind,        -> { order(:kind, :version) }

  # Returns the first active NDA metadata record for a specific account + entity.
  # Falls back to any active NDA for the account when no entity-scoped record exists.
  #
  # Usage:
  #   meta = IgsignTemplateMetadata.entity_nda_for(account, 'iti')
  #   template = meta&.template
  def self.entity_nda_for(account, entity_key)
    base = joins(:template)
             .where(kind: 'nda', status: 'active')
             .where(templates: { account_id: account.id })

    # Prefer entity-specific record (entity_scope @> '["iti"]')
    entity_specific = base.where('entity_scope @> ?', [entity_key.to_s].to_json).first
    return entity_specific if entity_specific

    # Fallback: any active NDA template for this account (entity_scope empty or any)
    base.first
  end

  # Increment version when metadata is updated (called by admin controller on save)
  def bump_version!
    increment!(:version)
  end

  def active?
    status == 'active'
  end

  def deprecated?
    status == 'deprecated'
  end

  def draft?
    status == 'draft'
  end

  def kind_label
    KIND_LABELS.fetch(kind, kind.humanize)
  end

  def status_label
    STATUS_LABELS.fetch(status, status.humanize)
  end

  # Find or build (but don't save) a metadata record for the given template
  def self.for_template(template)
    find_or_initialize_by(template: template)
  end
end
