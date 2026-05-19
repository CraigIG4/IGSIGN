# frozen_string_literal: true

# IGSIGN — Sends the final audit bundle after the counterparty has signed.
# Audit bundle includes:
#   - The fully executed contract (all pages signed)
#   - The IGSIGN audit trail PDF (signing certificate, ECT Act details, IP logs)
# Delivered to: both IG requestor + counterparty.
class CafAuditBundleSender
  def initialize(caf_workflow)
    @caf = caf_workflow
  end

  def call
    ActiveRecord::Base.transaction do
      stage2 = counterparty_stage
      unless stage2&.all_submitters_complete?
        return { success: false, error: 'Counterparty stage not found or not complete' }
      end

      # Optimistic lock: only one concurrent caller can win the status transition.
      # If another thread already completed stage2, complete! returns false and
      # we return early — preventing duplicate audit emails and status updates.
      return { success: true } unless stage2.complete!

      @caf.update!(status: 'complete', status_updated_at: Time.current)
    end

    # Send audit bundle emails outside the transaction so DB is committed first.
    # Reached only by the one caller whose complete! call returned true.
    deliver_audit_bundle

    Rails.logger.info("[CafAuditBundleSender] CAF #{@caf.id} fully complete — audit bundle sent")
    { success: true }
  rescue StandardError => e
    backtrace = e.backtrace.first(5).join("\n")
    Rails.logger.error("[CafAuditBundleSender] failed for CAF #{@caf.id}: #{e.message}\n#{backtrace}")
    { success: false, error: e.message }
  end

  private

  def counterparty_stage
    caf_submission = @caf.caf_submission
    caf_stages = caf_submission&.caf_stages
    caf_stages&.ordered_by_position&.second
  end

  def deliver_audit_bundle
    recipients  = audit_recipients
    signed_docs = collect_signed_documents

    recipients.each do |recipient|
      CafAuditMailer.audit_bundle(
        caf:              @caf,
        to_name:          recipient[:name],
        to_email:         recipient[:email],
        signed_documents: signed_docs
      ).deliver_later
    rescue StandardError => e
      Rails.logger.warn("[CafAuditBundleSender] Failed to send to #{recipient[:email]}: #{e.message}")
    end
  end

  # Returns the ActiveStorage::Attachment objects for all counterparty-visible
  # (internal_only: false) documents attached to the CAF submission.
  # Works for both NDA (dynamically generated agreement PDF) and non-NDA
  # (uploaded contract blobs).
  #
  # Falls back gracefully to an empty array if the submission is missing or
  # has no CafStageDocument records (e.g., workflow created before this fix).
  def collect_signed_documents
    submission = @caf.caf_submission
    return [] unless submission

    visible_uuids = submission.caf_stage_documents
                              .where(internal_only: false)
                              .pluck(:document_uuid)
                              .to_set
    return [] if visible_uuids.empty?

    submission.documents
              .attachments
              .includes(:blob)
              .select { |att| visible_uuids.include?(att.uuid) }
  rescue StandardError => e
    Rails.logger.warn("[CafAuditBundleSender] collect_signed_documents failed for caf #{@caf.id}: #{e.message}")
    []
  end

  def audit_recipients
    recipients = []

    recipients << { name: @caf.requestor_name, email: @caf.requestor_email } if @caf.requestor_email.present?

    if @caf.counterparty_email.present?
      recipients << { name: @caf.counterparty_name.presence || @caf.contracting_party, email: @caf.counterparty_email }
    end

    # Also CC legal@ignitiongroup.co.za for the IG filing record
    recipients << { name: 'IGSIGN Legal', email: 'legal@ignitiongroup.co.za' }

    recipients.uniq { |r| r[:email] }
  end
end
