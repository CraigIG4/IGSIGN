# frozen_string_literal: true

# IGSIGN — Links related CafWorkflows together (e.g. addendum → parent MSA).
# Used by GCinmyPOCKET (Sprint 3) to assemble cross-workflow context.
class ContractFamilyMember < ApplicationRecord
  belongs_to :caf_workflow
  belongs_to :linked_workflow, class_name: 'CafWorkflow', optional: true

  validates :document_name, presence: true
  validates :linked_workflow_id, uniqueness: { scope: :caf_workflow_id }, allow_nil: true

  ROLES = %w[master schedule sow addendum nda].freeze
  validates :role, inclusion: { in: ROLES }, allow_nil: true

  scope :ordered, -> { order(:position, :created_at) }
end
