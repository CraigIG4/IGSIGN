# frozen_string_literal: true

# IGSIGN — Contract Approval Form Workflow
# Lifecycle: draft → pending_ig → ig_complete → sent_counterparty → complete
# == Schema Information
#
# Table name: caf_workflows
#
#  id                     :bigint           not null, primary key
#  agreement_type         :string
#  caf_type               :string           not null
#  contracting_party      :string
#  counterparty_email     :string
#  counterparty_name      :string
#  entity                 :string           not null
#  high_level_summary     :text
#  ignition_company       :string
#  long_form_data         :jsonb
#  mandate_description    :text
#  parsed_contract_data   :jsonb
#  requestor_email        :string
#  requestor_name         :string
#  signatories            :jsonb
#  status                 :string           default("draft"), not null
#  status_updated_at      :datetime
#  created_at             :datetime         not null
#  updated_at             :datetime         not null
#  account_id             :bigint           not null
#  caf_submission_id      :bigint
#  company_id             :bigint
#  contract_submission_id :bigint
#  created_by_user_id     :bigint           not null
#  template_id            :bigint
#
# Indexes
#
#  index_caf_workflows_on_account_id                 (account_id)
#  index_caf_workflows_on_account_id_and_created_at  (account_id,created_at)
#  index_caf_workflows_on_account_id_and_status      (account_id,status)
#  index_caf_workflows_on_caf_submission_id          (caf_submission_id)
#  index_caf_workflows_on_company_id                 (company_id)
#  index_caf_workflows_on_contract_submission_id     (contract_submission_id)
#  index_caf_workflows_on_created_by_user_id         (created_by_user_id)
#  index_caf_workflows_on_template_id                (template_id)
#
# Foreign Keys
#
#  fk_rails_...  (account_id => accounts.id)
#  fk_rails_...  (caf_submission_id => submissions.id)
#  fk_rails_...  (company_id => companies.id)
#  fk_rails_...  (contract_submission_id => submissions.id)
#  fk_rails_...  (created_by_user_id => users.id)
#  fk_rails_...  (template_id => templates.id)
#
class CafWorkflow < ApplicationRecord
  AGREEMENT_TYPES = {
    'nda' => 'NDA — Non-Disclosure Agreement',
    'msa' => 'MSA — Master Services Agreement',
    'addendum' => 'Addendum',
    'sla' => 'SLA — Service Level Agreement',
    'vendor' => 'Vendor Agreement',
    'employment' => 'Employment Contract',
    'policy' => 'Policy Acknowledgement',
    'other' => 'Other Agreement'
  }.freeze

  AGREEMENT_TO_CAF_TYPE = {
    'nda' => 'nda',
    'msa' => 'long_form',
    'addendum' => 'short_form',
    'sla' => 'long_form',
    'vendor' => 'long_form',
    'employment' => 'short_form',
    'policy' => 'nda',
    'other' => 'long_form'
  }.freeze

  CAF_LABELS = {
    'nda' => 'NDA Approval Form',
    'msa' => 'Contract Approval Form',
    'addendum' => 'Addendum Approval Form',
    'sla' => 'Contract Approval Form',
    'vendor' => 'Contract Approval Form',
    'employment' => 'Employment Approval Form',
    'policy' => 'Policy Acknowledgement Form',
    'other' => 'Contract Approval Form'
  }.freeze

  STATUSES = %w[draft pending_ig ig_complete sent_counterparty complete cancelled].freeze

  # :customer (0) — counterparty is a customer of Ignition (default)
  # :supplier (1) — counterparty is a supplier; adds Procurement approver to Stage 0
  enum :commercial_relationship, { customer: 0, supplier: 1 }, prefix: :commercial

  # CafFieldSchema uses :contract_type as the schema key; the DB column is agreement_type.
  alias_attribute :contract_type, :agreement_type

  belongs_to :account
  belongs_to :created_by_user, class_name: 'User'
  belongs_to :company, optional: true
  belongs_to :template, class_name: 'Template', optional: true
  belongs_to :caf_submission, class_name: 'Submission', optional: true
  belongs_to :contract_submission, class_name: 'Submission', optional: true

  # Contract Family — related agreements for GCinmyPOCKET context assembly (Sprint 2.5)
  has_many :contract_family_members, dependent: :destroy
  has_many :linked_workflows, through: :contract_family_members

  has_one_attached :contract_document

  before_validation :derive_caf_type_from_agreement_type

  validates :entity, presence: true,
                     inclusion: { in: -> { IgSignatories.all_entity_keys } }
  validates :status, presence: true, inclusion: { in: STATUSES }
  validates :counterparty_email,
            format: { with: URI::MailTo::EMAIL_REGEXP }, allow_blank: true

  scope :active,   -> { where.not(status: %w[complete cancelled]) }
  scope :pending,  -> { where(status: %w[pending_ig sent_counterparty]) }
  scope :complete, -> { where(status: 'complete') }
  scope :draft,    -> { where(status: 'draft') }
  scope :recent,   -> { order(created_at: :desc) }
  scope :overdue,  -> {
    where(status: %w[pending_ig ig_complete sent_counterparty])
      .where('COALESCE(status_updated_at, updated_at) <= ?', 9.days.ago)
  }

  # ── Labels ────────────────────────────────────────────────────────────────

  def entity_name
    IgSignatories.entity_name(entity)
  end

  def agreement_type_label
    AGREEMENT_TYPES.fetch(agreement_type.to_s, agreement_type.to_s.humanize)
  end

  def caf_label
    CAF_LABELS.fetch(agreement_type.to_s, 'Contract Approval Form')
  end

  def caf_type_label
    { 'nda' => 'NDA', 'short_form' => 'Short Form', 'long_form' => 'Full CAF' }
      .fetch(caf_type.to_s, caf_type.to_s.humanize)
  end

  def status_label
    {
      'draft' => 'Draft',
      'pending_ig' => 'Pending IG Approval',
      'ig_complete' => 'IG Approved',
      'sent_counterparty' => 'With Counterparty',
      'complete' => 'Complete',
      'cancelled' => 'Cancelled'
    }.fetch(status, status.humanize)
  end

  def status_badge_class
    case status
    when 'draft'             then 'badge-neutral'
    when 'pending_ig'        then 'badge-warning'
    when 'ig_complete'       then 'badge-info'
    when 'sent_counterparty' then 'badge-primary'
    when 'complete'          then 'badge-success'
    when 'cancelled'         then 'badge-error'
    else                          'badge-ghost'
    end
  end

  def auto_assign_signatories!
    chain = IgSignatories.chain_for(entity, derived_caf_type, is_supplier: commercial_supplier?)[:stage1]
    self.signatories = chain.map.with_index do |entry, idx|
      {
        'position'    => idx,
        'role'        => entry[:title],
        'name'        => entry[:name],
        'email'       => entry[:email],
        'chain_position' => entry[:position].to_s,
        'placeholder' => false
      }
    end
  end

  def draft?             = status == 'draft'
  def pending_ig?        = status == 'pending_ig'
  def ig_complete?       = status == 'ig_complete'
  def sent_counterparty? = status == 'sent_counterparty'
  def complete?          = status == 'complete'
  def cancelled?         = status == 'cancelled'

  # ── Timeline / overdue helpers ─────────────────────────────────────────────

  # Number of whole days the workflow has been in its current status.
  # Falls back to updated_at if status_updated_at is not yet stamped.
  def days_in_current_stage
    reference = status_updated_at || updated_at
    ((Time.current - reference) / 1.day).to_i
  end

  # True when the workflow has been in an active signing status for >9 days.
  def overdue?
    !%w[complete cancelled draft].include?(status) && days_in_current_stage > 9
  end

  # True when the workflow has been waiting for >5 days (yellow warning threshold).
  def slightly_overdue?
    !%w[complete cancelled draft].include?(status) && days_in_current_stage > 5
  end

  # Returns the name of the person/party currently holding the workflow,
  # working entirely from already-loaded ActiveRecord associations.
  # Returns nil if the association data hasn't been eager-loaded or
  # the stage can't be determined.
  def current_holder_name
    case status
    when 'sent_counterparty'
      counterparty_name.presence || contracting_party.presence || 'Counterparty'
    when 'pending_ig', 'ig_complete'
      return nil unless caf_submission

      active_stage = caf_submission.caf_stages.to_a.find { |s| s.status == 'active' }
      return nil unless active_stage

      first_unsigned = active_stage.caf_stage_submitters.to_a
                                   .sort_by(&:position)
                                   .find { |css| css.submitter.completed_at.nil? }
      first_unsigned&.submitter&.name
    end
  end

  # Returns the wizard step symbol a draft agreement should resume at.
  # Used by the agreements index "Continue →" link so that each agreement
  # deep-links to the correct step rather than always starting at upload.
  #
  #   :review   — NDA (no upload step) or upload + fields done
  #   :position — document uploaded but field placement not yet confirmed
  #   :upload   — no document uploaded yet
  def next_draft_step
    return :review if agreement_type == 'nda'
    return :upload if template_id.blank?
    return :position if template&.fields.blank?

    :review
  end

  private

  # ── Sprint 5: Contracts Dashboard ─────────────────────────────────────────

  # Returns an array of risk flag strings derived from native columns.
  # Used by the dashboard to show colour-coded risk badges per agreement.
  # rubocop:disable Metrics/MethodLength, Metrics/CyclomaticComplexity, Metrics/PerceivedComplexity
  def risk_flags
    flags = []
    flags << 'No liability cap'                     if liability_cap.blank? || liability_cap == 'Not Included'
    flags << 'No indirect/consequential exclusion'  if liability_exclusion_indirect == 'Not Included'
    flags << 'Auto-renewal — notice <30 days'       if auto_renewal? && notice_period_days.present? && notice_period_days < 30
    flags << 'Auto-renewal — no notice period'      if auto_renewal? && notice_period_days.nil?
    flags << 'Expired'                              if expiry_date.present? && expiry_date < Date.today && !complete?
    flags << 'No expiry date'                       if expiry_date.nil? && !auto_renewal?
    flags << 'No governing law'                     if governing_law.blank?
    flags << 'No dispute resolution clause'         if dispute_resolution == 'Not Included'
    flags << 'Late payment terms (>60 days)'        if payment_terms_days.present? && payment_terms_days > 60 && commercial_supplier?
    flags << 'IG locked in exclusively'             if exclusivity == 'IG exclusive (locked in)'
    flags << 'Subcontracting without consent'       if subcontracting.present? && subcontracting.downcase.include?('without consent')
    flags << 'No data protection clause'            if data_protection_clause == 'Not Included'
    flags << 'Change of control — no provision'     if change_of_control == 'No provision'
    flags << 'Assignment — no provision'            if assignment == 'No provision'
    flags
  end
  # rubocop:enable Metrics/MethodLength, Metrics/CyclomaticComplexity, Metrics/PerceivedComplexity

  # Percentage of CafFieldSchema dashboard fields that have a non-nil value.
  # Used as a data quality indicator in the contracts register.
  def data_completeness_score
    cols = CafFieldSchema.dashboard_fields.filter_map { |f| f[:caf_column] }
    return 0 if cols.empty?

    filled = cols.count do |col|
      val = public_send(col)
      val.present?
    rescue StandardError
      false
    end
    (filled * 100.0 / cols.count).round
  end

  def derived_caf_type
    AGREEMENT_TO_CAF_TYPE.fetch(agreement_type.to_s, caf_type.presence || 'long_form')
  end

  def derive_caf_type_from_agreement_type
    self.caf_type = derived_caf_type if caf_type.blank?
  end
end
