# frozen_string_literal: true
# IGSIGN — Processes DocuSeal submitter completion events for CAF workflows.
# Called from SubmissionEventsController (or Submission#after_complete callback).
# Determines which CAF stage just completed and fires the appropriate handler.
class CafWebhookHandler
  def initialize(submission)
    @submission = submission
  end

  # Called after a submitter signs.
  # Checks whether the current active stage is now fully signed and fires
  # the correct handler.
  def call
    caf = find_caf_workflow
    return unless caf

    active_stage = caf.caf_submission
                      &.caf_stages
                      &.where(status: 'active')
                      &.ordered_by_position
                      &.first
    return unless active_stage

    return unless active_stage.all_submitters_complete?

    case active_stage.position
    when 0
      # Internal IG stage complete → strip CAF, send to counterparty
      CafCompletionHandler.new(caf).call
    when 1
      # Counterparty stage complete → send audit bundle
      CafAuditBundleSender.new(caf).call
    else
      Rails.logger.warn("[CafWebhookHandler] Unknown stage position #{active_stage.position} for CAF #{caf.id}")
    end
  end

  private

  def find_caf_workflow
    CafWorkflow.find_by(caf_submission_id: @submission.id)
  end
end
