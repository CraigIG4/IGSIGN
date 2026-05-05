# frozen_string_literal: true
# IGSIGN — Fired when all IG internal signatories have completed Stage 1.
# Responsibilities:
#   1. Mark Stage 1 complete, strip internal CAF pages from the document bundle.
#   2. Activate Stage 2 (counterparty signing) and notify counterparty.
#   3. Update CafWorkflow status → sent_counterparty.
class CafCompletionHandler
  def initialize(caf_workflow)
    @caf = caf_workflow
  end

  # Called by webhook or CafStage#check_completion! after last IG submitter signs.
  def call
    ActiveRecord::Base.transaction do
      stage1 = internal_stage
      return { success: false, error: 'Internal stage not found or not complete' } unless stage1&.all_submitters_complete?

      # ── 1. Mark Stage 1 complete (uses built-in complete! which strips + advances) ──
      stage1.complete!

      # ── 2. Populate + activate Stage 2 (counterparty) ───────────────────────
      # Note: stage1.complete! already calls advance_to_next_stage!, which activates
      # stage2 IF submitters are already assigned. We also ensure counterparty
      # submitter is populated before activation happens.
      stage2 = counterparty_stage
      if stage2&.status == 'pending'
        populate_counterparty_submitters(stage2)
        stage2.activate!
      elsif stage2&.status == 'active'
        # Already activated by complete! — just ensure counterparty submitter exists
        populate_counterparty_submitters(stage2)
      end

      # ── 4. Update workflow status ─────────────────────────────────────────────
      @caf.update!(status: 'sent_counterparty')

      Rails.logger.info("[CafCompletionHandler] CAF #{@caf.id} IG stage complete → counterparty notified")
    end

    { success: true }
  rescue => e
    Rails.logger.error("[CafCompletionHandler] failed for CAF #{@caf.id}: #{e.message}\n#{e.backtrace.first(5).join("\n")}")
    { success: false, error: e.message }
  end

  private

  def internal_stage
    @caf.caf_submission&.caf_stages&.ordered_by_position&.first
  end

  def counterparty_stage
    @caf.caf_submission&.caf_stages&.ordered_by_position&.second
  end

  # Remove pages flagged as internal_only from the document bundle.
  # The contract document itself (internal_only: false) is preserved for
  # the counterparty to sign.
  # Ensure Stage 2 has a submitter for the counterparty.
  # The CAF stores counterparty_name + counterparty_email on the workflow.
  def populate_counterparty_submitters(stage2)
    submission = @caf.caf_submission
    return if stage2.caf_stage_submitters.exists?

    submitter = submission.submitters.create!(
      account:  @caf.account,
      name:     @caf.counterparty_name.presence || @caf.contracting_party,
      email:    @caf.counterparty_email,
      uuid:     SecureRandom.uuid,
      slug:     SecureRandom.base58(14),
      metadata: { 'caf_role' => 'Counterparty Signatory', 'stage' => 2 },
    )

    CafStageSubmitter.create!(
      caf_stage: stage2,
      submitter:  submitter,
      role:       'Counterparty Signatory',
      position:   0,
    )
  end

end
