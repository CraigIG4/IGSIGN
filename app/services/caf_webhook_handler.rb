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
  #
  # Stage routing convention (set by CafSubmissionCreator#build_default_stages):
  #   - Last stage by position  = Counterparty Signing
  #   - Second-to-last stage    = last internal stage (fires CafCompletionHandler)
  #   - Any earlier stage       = intermediate internal stage (advance quietly)
  #
  # This is position-count-agnostic: works for 2-stage (NDA), 3-stage (standard),
  # and 4-stage (Spot Connect: Stage 0 → Siddeek → Sean → Counterparty) flows.
  def call
    caf = find_caf_workflow
    return unless caf

    active_stage = active_stage_for(caf)
    return unless active_stage

    return unless active_stage.all_submitters_complete?

    stages = caf.caf_submission&.caf_stages&.ordered_by_position&.to_a
    return unless stages&.any?

    last_stage          = stages.last
    last_internal_stage = stages[-2]  # nil only when there is a single stage (misconfiguration)

    if active_stage.id == last_stage&.id
      # Counterparty stage complete → record signatory memory, then send audit bundle
      record_counterparty_signatories!(caf, active_stage)
      CafAuditBundleSender.new(caf).call
    elsif active_stage.id == last_internal_stage&.id
      # Last internal stage (parallel-approval or final group signer) complete →
      # strip internal docs, populate counterparty submitter, update workflow status.
      CafCompletionHandler.new(caf).call
    else
      # Intermediate internal stage (e.g. Stage 0 parallel when group-signer stages follow).
      # CafStage#complete! already called advance_to_next_stage! inside the submitter
      # completion callback — we just mark the stage complete here so that call is idempotent.
      active_stage.complete!
    end
  end

  private

  def find_caf_workflow
    CafWorkflow.find_by(caf_submission_id: @submission.id)
  end

  def active_stage_for(caf)
    caf_stages = caf.caf_submission&.caf_stages
    caf_stages&.where(status: 'active')&.ordered_by_position&.first
  end

  # Records each completed counterparty submitter against the company
  # so future workflows can pre-populate the counterparty fields.
  # Failure is swallowed — signatory recording must never block the audit bundle.
  def record_counterparty_signatories!(caf, stage)
    return unless caf.company_id

    stage.submitters.each do |submitter|
      next if submitter.email.blank?

      caf.company.record_signatory!(
        submitter.name,
        submitter.email,
        workflow_id: caf.id
      )
    end
  rescue StandardError => e
    Rails.logger.error(
      "[CafWebhookHandler] Signatory recording failed for CAF #{caf.id}: #{e.message}"
    )
  end
end
