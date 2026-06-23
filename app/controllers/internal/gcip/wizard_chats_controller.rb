# frozen_string_literal: true

module Internal
  module Gcip
    # POCKET GC chat endpoint for the upload wizard.
    # Authenticated via Devise user session (not submitter token).
    # Available to any admin user who has access to the workflow.
    class WizardChatsController < ApplicationController
      before_action :authenticate_user!
      skip_authorization_check

      before_action :load_workflow

      # POST /internal/gcip/wizard_chats
      # Params:
      #   caf_workflow_id — the draft workflow being uploaded
      #   question        — the user's question
      #   history         — array of prior { role, content } pairs (optional)
      def create
        result = ContractChatService.answer_for_uploader(
          question:             params[:question].to_s.strip,
          caf_workflow_id:      @workflow.id,
          user:                 current_user,
          conversation_history: Array(params[:history])
        )

        if result[:error]
          render json: { error: result[:error] }, status: :unprocessable_entity
        else
          render json: { answer: result[:answer] }
        end
      end

      private

      def load_workflow
        @workflow = current_account.caf_workflows.find_by(id: params[:caf_workflow_id].to_i)
        render json: { error: 'Agreement not found' }, status: :not_found unless @workflow
      end
    end
  end
end
