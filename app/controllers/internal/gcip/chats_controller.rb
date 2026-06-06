# frozen_string_literal: true

module Internal
  module Gcip
    # GCinmyPOCKET chat API endpoint.
    # Authenticated by submitter slug (same pattern as SubmitFormController).
    # Rate-limited to 20 requests per minute per slug via Rack::Attack (if configured).
    # Stage 2 counterparty submitters are rejected at the service level.
    class ChatsController < ApplicationController
      skip_before_action :authenticate_user!, raise: false
      skip_authorization_check

      before_action :load_submitter
      before_action :verify_workflow_access

      # POST /internal/gcip/chats
      # Params:
      #   submitter_slug  — identifies the submitter (in URL or body)
      #   caf_workflow_id — the workflow being signed
      #   question        — the user's question
      #   history         — array of prior { role, content } pairs (optional)
      def create
        result = ContractChatService.answer(
          question:             params[:question].to_s.strip,
          caf_workflow_id:      params[:caf_workflow_id].to_i,
          submitter:            @submitter,
          conversation_history: Array(params[:history])
        )

        if result[:error]
          render json: { error: result[:error] }, status: :unprocessable_entity
        else
          render json: { answer: result[:answer] }
        end
      end

      private

      def load_submitter
        slug = params[:submitter_slug] || params[:slug]
        @submitter = Submitter.find_by(slug: slug)

        render json: { error: 'Invalid signing session' }, status: :unauthorized unless @submitter
      end

      def verify_workflow_access
        return unless @submitter

        workflow_id    = params[:caf_workflow_id].to_i
        submission_id  = @submitter.submission_id

        # Submitter must belong to either the CAF signing submission or the
        # contract (counterparty) submission for the requested workflow.
        authorised = CafWorkflow.where(id: workflow_id)
                                .where(
                                  'caf_submission_id = :sid OR contract_submission_id = :sid',
                                  sid: submission_id
                                ).exists?

        render json: { error: 'Access denied' }, status: :forbidden unless authorised
      rescue StandardError
        render json: { error: 'Access denied' }, status: :forbidden
      end
    end
  end
end
