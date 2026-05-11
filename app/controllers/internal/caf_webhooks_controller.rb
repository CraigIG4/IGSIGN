# frozen_string_literal: true

# IGSIGN — Internal webhook endpoint called by DocuSeal's ProcessSubmitterCompletionJob
# after each submitter signs. Advances CAF stage pipeline (Stage 1 → Stage 2 → audit bundle).
#
# Authentication: X-Internal-Webhook-Secret header must match INTERNAL_WEBHOOK_SECRET env var.
# This endpoint is NOT exposed to external callers — it is called in-process by the Sidekiq job.
module Internal
  class CafWebhooksController < ApplicationController
    skip_before_action :authenticate_user!
    skip_authorization_check

    before_action :verify_internal_secret

    def create
      submission = find_submission
      unless submission
        Rails.logger.warn("[CafWebhook] No submission found for id=#{params[:submission_id]}")
        return head :not_found
      end

      caf = CafWorkflow.find_by(caf_submission_id: submission.id) ||
            CafWorkflow.find_by(contract_submission_id: submission.id)

      unless caf
        # Not a CAF submission — this is normal (regular DocuSeal submissions pass through too)
        return head :ok
      end

      Rails.logger.info("[CafWebhook] Received event submission=#{submission.id} caf=#{caf.id} " \
                        "submitter=#{params[:submitter_id]}")

      CafWebhookHandler.new(submission).call

      head :ok
    rescue StandardError => e
      Rails.logger.error("[CafWebhook] Error caf=#{caf&.id}: #{e.message}\n#{e.backtrace.first(3).join("\n")}")
      head :internal_server_error
    end

    private

    def verify_internal_secret
      expected = ENV.fetch('INTERNAL_WEBHOOK_SECRET', nil)

      if expected.blank?
        Rails.logger.error('[CafWebhook] INTERNAL_WEBHOOK_SECRET env var is not set')
        head :service_unavailable and return
      end

      provided = request.headers['X-Internal-Webhook-Secret']
      return if ActiveSupport::SecurityUtils.secure_compare(expected, provided.to_s)

      Rails.logger.warn("[CafWebhook] Invalid secret from #{request.remote_ip}")
      head :unauthorized
    end

    def find_submission
      return unless params[:submission_id].present?

      Submission.find_by(id: params[:submission_id])
    end
  end
end
