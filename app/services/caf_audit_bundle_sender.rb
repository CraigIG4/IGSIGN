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
      return { success: false, error: 'Counterparty stage not found or not complete' } unless stage2&.all_submitters_complete?

      stage2.update!(status: 'complete', completed_at: Time.current)
      @caf.update!(status: 'complete')
    end

    # Send audit bundle emails outside the transaction so DB is committed first
    deliver_audit_bundle

    Rails.logger.info("[CafAuditBundleSender] CAF #{@caf.id} fully complete — audit bundle sent")
    { success: true }
  rescue => e
    Rails.logger.error("[CafAuditBundleSender] failed for CAF #{@caf.id}: #{e.message}\n#{e.backtrace.first(5).join("\n")}")
    { success: false, error: e.message }
  end

  private

  def counterparty_stage
    @caf.caf_submission&.caf_stages&.ordered_by_position&.second
  end

  def deliver_audit_bundle
    recipients = audit_recipients

    recipients.each do |recipient|
      CafAuditMailer.audit_bundle(
        caf:        @caf,
        to_name:    recipient[:name],
        to_email:   recipient[:email],
      ).deliver_later
    rescue => e
      Rails.logger.warn("[CafAuditBundleSender] Failed to send to #{recipient[:email]}: #{e.message}")
    end
  end

  def audit_recipients
    recipients = []

    # IG Requestor
    if @caf.requestor_email.present?
      recipients << { name: @caf.requestor_name, email: @caf.requestor_email }
    end

    # Counterparty
    if @caf.counterparty_email.present?
      recipients << { name: @caf.counterparty_name.presence || @caf.contracting_party, email: @caf.counterparty_email }
    end

    # Also CC legal@ignitiongroup.co.za for the IG filing record
    recipients << { name: 'IGSIGN Legal', email: 'legal@ignitiongroup.co.za' }

    recipients.uniq { |r| r[:email] }
  end
end
