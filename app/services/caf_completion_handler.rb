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
      unless stage1&.all_submitters_complete?
        return { success: false, error: 'Internal stage not found or not complete' }
      end

      # ── 1. Mark Stage 1 complete ─────────────────────────────────────────────
      # complete! uses an optimistic status-transition lock (WHERE status = 'active').
      # If another thread already completed this stage, it returns false — we
      # return early so no side-effects (events, emails, status updates) are
      # duplicated.  Both concurrent callers end up with { success: true }.
      return { success: true } unless stage1.complete!

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

      # ── 3. Record stage-transition audit event ───────────────────────────────
      # Pass stage1 directly — internal_stage queries for status:'active', which
      # would return nil here because stage1.complete! already changed it to 'complete'.
      record_stage_transition_event(from_stage: stage1, to_stage: stage2)

      # ── 4. Update workflow status ─────────────────────────────────────────────
      @caf.update!(status: 'sent_counterparty', status_updated_at: Time.current)

      Rails.logger.info("[CafCompletionHandler] CAF #{@caf.id} IG stage complete → counterparty notified")
    end

    { success: true }
  rescue StandardError => e
    Rails.logger.error(
      "[CafCompletionHandler] failed for CAF #{@caf.id}: #{e.message}\n#{e.backtrace.first(5).join("\n")}"
    )
    { success: false, error: e.message }
  end

  private

  # Returns the currently active internal stage.
  # In multi-stage flows (parallel approval → group signer(s) → counterparty),
  # CafCompletionHandler is fired for the LAST internal stage — which may be at
  # position 0 (NDA / no group signers) or position N-1 (final group signer).
  # Using the active stage rather than `.first` makes this position-agnostic.
  def internal_stage
    @caf.caf_submission&.caf_stages&.where(status: 'active')&.ordered_by_position&.first
  end

  # Returns the counterparty stage.
  # By CafSubmissionCreator convention the counterparty stage is always the last
  # one by position, regardless of how many internal stages precede it.
  def counterparty_stage
    @caf.caf_submission&.caf_stages&.ordered_by_position&.last
  end

  # Creates a SubmissionEvent documenting the last-internal → counterparty transition,
  # recording which document UUIDs are visible to the counterparty and which
  # remain concealed (internal_only: true).
  #
  # from_stage and to_stage are passed explicitly because internal_stage queries
  # for status:'active' — by call time stage1 is already 'complete'.
  def record_stage_transition_event(from_stage:, to_stage:)
    submission = @caf.caf_submission
    return unless submission

    visible_uuids   = submission.caf_stage_documents.where(internal_only: false).pluck(:document_uuid)
    concealed_uuids = submission.caf_stage_documents.where(internal_only: true).pluck(:document_uuid)

    SubmissionEvent.create!(
      submission:      submission,
      account_id:      @caf.account_id,
      event_type:      'stage_transition_to_counterparty',
      event_timestamp: Time.current,
      data: {
        stage_from:               from_stage&.position,
        stage_to:                 to_stage&.position,
        caf_workflow_id:          @caf.id,
        visible_document_uuids:   visible_uuids,
        concealed_document_uuids: concealed_uuids
      }
    )
  rescue StandardError => e
    # Audit event failure must not abort the signing flow.
    Rails.logger.error("[CafCompletionHandler] Failed to record stage transition event: #{e.message}")
  end

  def populate_counterparty_submitters(stage2)
    submission = @caf.caf_submission
    return if stage2.caf_stage_submitters.exists?

    if @caf.counterparty_email.blank?
      Rails.logger.error(
        "[CafCompletionHandler] counterparty_email is blank for caf #{@caf.id} — " \
        'cannot activate Stage 2. Resolve the missing email in the admin panel.'
      )
      return
    end

    # Reuse the stable UUID from the 'Counterparty' slot in the IGSIGN CAF
    # Template so the counterparty's signature fields are correctly bound.
    # Falls back to a fresh UUID only if the template slot is missing.
    tpl_sub = (submission.template&.submitters || []).find { |s| s['name'] == 'Counterparty' }
    counterparty_uuid = tpl_sub&.dig('uuid') || SecureRandom.uuid

    submitter = submission.submitters.create!(
      account: @caf.account,
      name: @caf.counterparty_name.presence || @caf.contracting_party,
      email: @caf.counterparty_email,
      uuid: counterparty_uuid,
      slug: SecureRandom.base58(14),
      metadata: { 'caf_role' => 'Counterparty Signatory', 'stage' => 2 }
    )

    CafStageSubmitter.create!(
      caf_stage: stage2,
      submitter: submitter,
      role: 'Counterparty Signatory',
      position: 0
    )
  end
end
