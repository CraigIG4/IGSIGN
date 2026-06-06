# frozen_string_literal: true

module LegalOps
  # Manages the Related Agreements panel on /legal_ops/workflows/:workflow_id.
  # All actions respond within a Turbo Frame so the panel updates in-place.
  class ContractFamilyMembersController < ApplicationController
    skip_authorization_check
    before_action :authenticate_user!
    before_action :require_admin!
    before_action :set_workflow

    # GET /legal_ops/workflows/:workflow_id/contract_family_members/search
    # Returns matching CafWorkflows for the live-search dropdown.
    def search
      q = params[:q].to_s.strip
      @results = if q.length >= 2
                   current_account.caf_workflows
                                  .where.not(id: @workflow.id)
                                  .where(
                                    'contracting_party ILIKE :q OR counterparty_name ILIKE :q',
                                    q: "%#{q}%"
                                  )
                                  .order(created_at: :desc)
                                  .limit(10)
                 else
                   CafWorkflow.none
                 end
      render partial: 'legal_ops/contract_family_members/search_results',
             locals: { results: @results, workflow: @workflow }
    end

    # POST /legal_ops/workflows/:workflow_id/contract_family_members
    def create
      member = @workflow.contract_family_members.build(member_params)

      # If linking to an existing workflow, use its name as document_name if blank
      if member.linked_workflow_id.present? && member.document_name.blank?
        linked = CafWorkflow.find_by(id: member.linked_workflow_id)
        member.document_name = linked&.contracting_party.presence ||
                               linked&.agreement_type_label.to_s
      end

      if member.save
        redirect_to legal_ops_workflow_path(@workflow),
                    notice: "Related agreement added: #{member.document_name}"
      else
        redirect_to legal_ops_workflow_path(@workflow),
                    alert: "Could not add: #{member.errors.full_messages.join(', ')}"
      end
    end

    # DELETE /legal_ops/workflows/:workflow_id/contract_family_members/:id
    def destroy
      member = @workflow.contract_family_members.find(params[:id])
      name   = member.document_name
      member.destroy!
      redirect_to legal_ops_workflow_path(@workflow),
                  notice: "Removed: #{name}"
    end

    private

    def require_admin!
      redirect_to root_path, alert: 'Not authorised.' unless current_user.role == User::ADMIN_ROLE
    end

    def set_workflow
      @workflow = current_account.caf_workflows.find(params[:workflow_id])
    end

    def member_params
      params.require(:contract_family_member).permit(
        :document_name, :linked_workflow_id, :role, :position
      )
    end
  end
end
