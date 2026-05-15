# frozen_string_literal: true

# IGSIGN metadata layer on top of DocuSeal's Template.
# Tracks kind (agreement type), owner, version, status, and notes.
# One record per DocuSeal template; created on first admin interaction.
#
# == Schema Information
#
# Table name: igsign_template_metadata
#
#  id          :bigint           not null, primary key
#  template_id :bigint           not null
#  owner_id    :bigint
#  kind        :string           not null, default: "other"
#  version     :integer          not null, default: 1
#  status      :string           not null, default: "draft"
#  notes       :text
#  created_at  :datetime         not null
#  updated_at  :datetime         not null
#
class IgsignTemplateMetadata < ApplicationRecord
  # Matches CafWorkflow::AGREEMENT_TYPES keys
  KINDS = %w[nda msa addendum sla vendor employment policy other].freeze

  STATUSES = %w[draft active deprecated].freeze

  STATUS_LABELS = {
    'draft'      => 'Draft',
    'active'     => 'Active',
    'deprecated' => 'Deprecated'
  }.freeze

  KIND_LABELS = {
    'nda'        => 'NDA',
    'msa'        => 'MSA',
    'addendum'   => 'Addendum',
    'sla'        => 'SLA',
    'vendor'     => 'Vendor',
    'employment' => 'Employment',
    'policy'     => 'Policy',
    'other'      => 'Other'
  }.freeze

  belongs_to :template
  belongs_to :owner, class_name: 'User', optional: true

  validates :kind,    presence: true, inclusion: { in: KINDS }
  validates :status,  presence: true, inclusion: { in: STATUSES }
  validates :version, presence: true, numericality: { only_integer: true, greater_than: 0 }

  scope :active,      -> { where(status: 'active') }
  scope :not_deprecated, -> { where.not(status: 'deprecated') }
  scope :by_kind,     -> { order(:kind, :version) }

  # Increment version when metadata is updated (called by controller on save)
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
