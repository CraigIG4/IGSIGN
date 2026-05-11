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
#  requestor_email        :string
#  requestor_name         :string
#  signatories            :jsonb
#  status                 :string           default("draft"), not null
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

  belongs_to :account
  belongs_to :created_by_user, class_name: 'User'
  belongs_to :company, optional: true
  belongs_to :template, class_name: 'Template', optional: true
  belongs_to :caf_submission, class_name: 'Submission', optional: true
  belongs_to :contract_submission, class_name: 'Submission', optional: true

  has_one_attached :contract_document

  before_validation :derive_caf_type_from_agreement_type

  validates :entity, presence: true,
                     inclusion: { in: IgSignatories::ENTITIES.keys.map(&:to_s) }
  validates :status, presence: true, inclusion: { in: STATUSES }
  validates :counterparty_email,
            format: { with: URI::MailTo::EMAIL_REGEXP }, allow_blank: true

  scope :active, -> { where.not(status: %w[complete cancelled]) }
  scope :pending, -> { where(status: %w[pending_ig sent_counterparty]) }
  scope :complete, -> { where(status: 'complete') }
  scope :draft, -> { where(status: 'draft') }
  scope :recent, -> { order(created_at: :desc) }

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
    chain = IgSignatories.chain_for(derived_caf_type, entity)[:stage1]
    self.signatories = chain.map.with_index do |entry, idx|
      {
        'position' => idx,
        'role' => entry[:role],
        'name' => entry[:name],
        'email' => entry[:email],
        'placeholder' => entry[:placeholder] || false,
        'key' => entry[:key].to_s
      }
    end
  end

  def draft?             = status == 'draft'
  def pending_ig?        = status == 'pending_ig'
  def ig_complete?       = status == 'ig_complete'
  def sent_counterparty? = status == 'sent_counterparty'
  def complete?          = status == 'complete'
  def cancelled?         = status == 'cancelled'

  private

  def derived_caf_type
    AGREEMENT_TO_CAF_TYPE.fetch(agreement_type.to_s, caf_type.presence || 'long_form')
  end

  def derive_caf_type_from_agreement_type
    self.caf_type = derived_caf_type if caf_type.blank?
  end
end
