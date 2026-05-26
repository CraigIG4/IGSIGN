# frozen_string_literal: true

# Declarative rules table: maps agreement_types + optional entity_scope →
# required stage chain per account.
#
# stages_config is a JSONB array:
#   [{ "name": "Internal CAF Approval",
#      "routing": "ordered",
#      "required_roles": ["BU Head","Procurement","BU Finance","CLO","CFO","COO","CEO"],
#      "strip_internal_on_complete": true },
#    { "name": "Counterparty Signing",
#      "routing": "parallel",
#      "required_roles": ["counterparty"] }]
#
# Resolution specificity (highest wins):
#   1. entity_scope matches the workflow's entity  >  entity_scope IS NULL (all entities)
#   2. value_threshold IS NOT NULL                 >  value_threshold IS NULL
#   3. agreement_types is a strict subset          >  agreement_types is a superset / wildcard
#
# == Schema Information
#
# Table name: caf_approval_matrices
#
#  id              :bigint           not null, primary key
#  active          :boolean          default(TRUE), not null
#  agreement_types :jsonb            default([]), not null
#  document_type   :string                        (legacy, nullable)
#  entity_scope    :jsonb
#  name            :string           not null
#  stages_config   :jsonb            default([]), not null
#  value_threshold :decimal(15, 2)
#  created_at      :datetime         not null
#  updated_at      :datetime         not null
#  account_id      :bigint           not null
#
class CafApprovalMatrix < ApplicationRecord
  # Keep in sync with CafWorkflow::AGREEMENT_TYPES
  AGREEMENT_TYPES = %w[nda msa addendum sla vendor employment policy other].freeze

  EVENT_CREATED     = 'MATRIX_CREATED'
  EVENT_UPDATED     = 'MATRIX_UPDATED'
  EVENT_DEACTIVATED = 'MATRIX_DEACTIVATED'
  EVENT_APPLIED     = 'MATRIX_APPLIED'

  belongs_to :account
  has_many   :matrix_audit_events, dependent: :destroy

  validates :name,            presence: true
  validates :stages_config,   presence: true
  validates :agreement_types, presence: { message: "must include at least one agreement type" }
  validates :name, uniqueness: {
    scope: :account_id,
    conditions: -> { where(active: true) },
    message: 'is already taken by another active matrix'
  }
  validate  :agreement_types_valid
  validate  :entity_scope_valid
  validate  :stages_config_valid

  before_validation :normalize_entity_scope

  scope :active,          -> { where(active: true) }
  scope :for_account,     ->(account) { where(account: account) }
  scope :by_name,         -> { order(:name) }

  # ---- Legacy lookup (kept for backward compat) -------------------------------

  def self.for(account, document_type)
    active.find_by(account: account, document_type: document_type.to_s)
  end

  # ---- Resolution logic -------------------------------------------------------
  #
  # Finds the single best-matching active matrix for the given context.
  # Returns nil if no matrix covers this combination.
  #
  # Options:
  #   agreement_type: (String, required) — e.g. "nda"
  #   entity:         (String, optional) — e.g. "iti"
  #   value:          (Numeric, optional) — contract value in ZAR
  #
  def self.resolve_for(account, agreement_type:, entity: nil, value: nil)
    candidates = active
      .for_account(account)
      .select { |m| m.covers_agreement_type?(agreement_type) }
      .select { |m| m.covers_entity?(entity) }
      .select { |m| m.covers_value?(value) }

    return nil if candidates.empty?

    # Score each candidate — higher is more specific
    candidates.max_by { |m| m.specificity_score(entity, value) }
  end

  # ---- Instance helpers -------------------------------------------------------

  def covers_agreement_type?(type)
    agreement_types.include?(type.to_s)
  end

  def covers_entity?(entity)
    # nil entity_scope means "applies to all entities"
    return true if entity_scope.nil? || entity_scope.empty?
    return false if entity.blank?

    entity_scope.include?(entity.to_s)
  end

  def covers_value?(value)
    # nil threshold means "no value restriction"
    return true if value_threshold.nil?
    return false if value.nil?

    value.to_d >= value_threshold
  end

  # Higher score = more specific match.  Broken into three independent bits:
  #   bit 2: entity is explicitly scoped   (4 points)
  #   bit 1: value threshold is set        (2 points)
  #   bit 0: agreement_types is a singleton(1 point)
  def specificity_score(_entity = nil, _value = nil)
    score = 0
    score += 4 if entity_scope.present?
    score += 2 if value_threshold.present?
    score += 1 if agreement_types.length == 1
    score
  end

  # Build (but do not save) stage records for a given submission.
  def build_stages_for(submission)
    stages_config.each_with_index.map do |cfg, idx|
      submission.caf_stages.build(
        name: cfg['name'],
        position: idx,
        routing: cfg.fetch('routing', 'ordered'),
        strip_internal_on_complete: cfg.fetch('strip_internal_on_complete', false),
        status: idx.zero? ? 'active' : 'pending'
      )
    end
  end

  def deactivate!(actor: nil)
    return false unless active?

    update!(active: false)
    log_audit_event(EVENT_DEACTIVATED, actor: actor)
    true
  end

  def log_audit_event(event_type, actor: nil, extra: {})
    matrix_audit_events.create!(
      account_id:  account_id,
      user_id:     actor&.id,
      event_type:  event_type,
      data:        {
        matrix_name:     name,
        agreement_types: agreement_types,
        entity_scope:    entity_scope,
        value_threshold: value_threshold&.to_s
      }.merge(extra)
    )
  end

  # ---- Presentation helpers ---------------------------------------------------

  def entity_scope_label
    if entity_scope.blank?
      'All entities'
    else
      entity_scope.map { |e|
        entity = IgEntity.find_by(key: e)
        entity ? entity.short_name : e
      }.join(', ')
    end
  end

  def agreement_types_label
    agreement_types.map(&:upcase).join(', ')
  end

  def stage_count
    stages_config.length
  end

  private

  def normalize_entity_scope
    return unless entity_scope.is_a?(Array)

    self.entity_scope = entity_scope.reject(&:blank?)
    self.entity_scope = nil if entity_scope.empty?
  end

  def agreement_types_valid
    return unless agreement_types.is_a?(Array)

    invalid = agreement_types - AGREEMENT_TYPES
    if invalid.any?
      errors.add(:agreement_types, "contains unknown types: #{invalid.join(', ')}")
    end
  end

  def entity_scope_valid
    return if entity_scope.nil?
    return unless entity_scope.is_a?(Array)

    valid_keys = IgSignatories.all_entity_keys
    invalid    = entity_scope - valid_keys
    errors.add(:entity_scope, "contains unknown entities: #{invalid.join(', ')}") if invalid.any?
  end

  def stages_config_valid
    return unless stages_config.is_a?(Array)

    stages_config.each_with_index do |stage, idx|
      errors.add(:stages_config, "stage #{idx}: 'name' is required") unless stage['name'].present?
      unless stage['required_roles'].is_a?(Array) && stage['required_roles'].any?
        errors.add(:stages_config, "stage #{idx}: 'required_roles' must be a non-empty array")
      end
    end
  end
end
