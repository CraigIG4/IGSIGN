# frozen_string_literal: true

# IGSIGN — Admin CAF Workflow Controller
# Accessible at /admin/workflows (admin users only).
# The user-facing agreement creation flow lives in AgreementsController (/agreements).
module Admin
  class WorkflowsController < ApplicationController
    skip_authorization_check
    before_action :authenticate_user!
    before_action :require_admin!
    before_action :set_caf, only: %i[show edit update destroy submit resend_invite contract_data update_contract_data reparse]

    def index
      @cafs = current_account.caf_workflows.recent
                             .includes(:created_by_user, :caf_submission, :contract_submission)
      @stats = {
        total:    @cafs.count,
        pending:  @cafs.pending.count,
        complete: @cafs.complete.count
      }
    end

    def show; end

    def new
      @caf = CafWorkflow.new
      @caf.requestor_name  = current_user.full_name
      @caf.requestor_email = current_user.email
      @caf.account         = current_account
    end

    def create
      @caf = CafWorkflow.new(caf_params)
      @caf.account          = current_account
      @caf.created_by_user  = current_user
      @caf.status           = 'draft'

      @caf.auto_assign_signatories!

      assign_bu_head!(@caf.signatories, params[:caf_workflow])

      custom = parse_custom_signatories(params[:caf_workflow][:custom_signatories])
      @caf.signatories = custom if custom

      if @caf.save
        redirect_to legal_ops_workflow_path(@caf), notice: 'CAF created. Review signatories and submit for approval.'
      else
        render :new, status: :unprocessable_content
      end
    end

    def edit; end

    def update
      if @caf.update(caf_params)
        redirect_to legal_ops_workflow_path(@caf), notice: 'CAF updated.'
      else
        render :edit, status: :unprocessable_content
      end
    end

    def destroy
      @caf.update!(status: 'cancelled')
      redirect_to legal_ops_workflows_path, notice: 'CAF cancelled.'
    end

    # POST /admin/workflows/:id/submit — Finalise draft and create DocuSeal submission
    def submit
      if @caf.draft?
        result = CafSubmissionCreator.new(@caf, current_user).call
        if result[:success]
          @caf.update!(status: 'pending_ig', caf_submission: result[:submission],
                       status_updated_at: Time.current)
          redirect_to legal_ops_workflow_path(@caf),
                      notice: 'CAF submitted for internal approval. Signatories have been notified.'
        else
          redirect_to legal_ops_workflow_path(@caf), alert: "Failed to create submission: #{result[:error]}"
        end
      else
        redirect_to legal_ops_workflow_path(@caf), alert: 'Only draft CAFs can be submitted.'
      end
    end

    # POST /admin/workflows/:id/resend_invite — re-queue invitation emails for all
    # unsigned active-stage submitters and reset their reminder counters so the
    # 2/5/9/14-day ladder restarts from the new send time.
    def resend_invite
      submission = @caf.caf_submission
      unless submission
        return redirect_to legal_ops_workflow_path(@caf), alert: 'No submission found for this workflow.'
      end

      active_stage = submission.caf_stages.active.ordered_by_position.first
      unless active_stage
        return redirect_to legal_ops_workflow_path(@caf),
                           alert: 'No active stage found — workflow may already be complete.'
      end

      count = 0
      active_stage.caf_stage_submitters
                  .not_completed
                  .includes(:submitter)
                  .find_each do |css|
        next if css.submitter.completed_at.present?

        SendSubmitterInvitationEmailJob.perform_async('submitter_id' => css.submitter_id)
        # Reset reminder ladder so the clock restarts from this new invite.
        css.update_columns(invited_at: nil, reminder_count: 0, reminder_sent_at: nil, escalated_at: nil)
        count += 1
      end

      redirect_to legal_ops_workflow_path(@caf),
                  notice: "Invitations resent to #{count} pending #{count == 1 ? 'signatory' : 'signatories'}."
    end

    # GET  /legal_ops/workflows/:id/contract_data — review and correct AI-extracted contract data
    # PATCH /legal_ops/workflows/:id/contract_data — save corrections
    def contract_data
      @fields = CafFieldSchema.active_fields_for(@caf)
      @provenance = @caf.parsed_data_provenance.presence || {}
      @data = @caf.parsed_contract_data.presence || {}
    end

    def update_contract_data
      provenance = @caf.parsed_data_provenance.presence || {}
      native_updates = {}
      provenance_updates = {}
      data_updates = (@caf.parsed_contract_data.presence || {}).dup

      contract_data_params.each do |key, raw_value|
        field = CafFieldSchema.field(key.to_sym)
        next unless field

        value = coerce_field_value(field, raw_value)
        data_updates[key] = value
        provenance_updates[key] = 'manual'

        if field[:caf_column]
          col_value = field[:type] == :array ? Array(value).join('; ') : value
          native_updates[field[:caf_column]] = col_value
        end
      end

      native_updates[:parsed_contract_data] = data_updates
      native_updates[:parsed_data_provenance] = provenance.merge(provenance_updates)

      @caf.update_columns(native_updates)
      redirect_to contract_data_legal_ops_workflow_path(@caf),
                  notice: 'Contract data saved. Dashboard will reflect these values.'
    end

    # POST /legal_ops/workflows/:id/reparse — re-enqueue ContractParsingJob
    # AI fields are overwritten; manual fields are preserved (handled in the job).
    def reparse
      ContractParsingJob.perform_later(@caf.id)
      redirect_to contract_data_legal_ops_workflow_path(@caf),
                  notice: 'Re-parsing queued. AI-extracted fields will be updated shortly.'
    end

    # GET /admin/workflows/signatories_for — AJAX: return signatories for entity + type
    def signatories_for
      entity   = params[:entity]
      caf_type = params[:caf_type]
      chain    = IgSignatories.chain_for(entity, caf_type)
      render json: chain
    end

    private

    def require_admin!
      redirect_to root_path, alert: 'Not authorised.' unless current_user.role == User::ADMIN_ROLE
    end

    def set_caf
      @caf = current_account.caf_workflows.find(params[:id])
    end

    def caf_params
      params.require(:caf_workflow).permit(
        :entity, :caf_type, :requestor_name, :requestor_email,
        :contracting_party, :ignition_company,
        :counterparty_name, :counterparty_email,
        :high_level_summary, :mandate_description,
        :contract_document
      )
    end

    def assign_bu_head!(sigs, caf_params)
      return unless caf_params[:bu_head_name].present?

      @caf.signatories = sigs.map do |s|
        if s['placeholder'] == true || s['key'] == 'bu_head'
          s.merge(
            'name'        => caf_params[:bu_head_name],
            'email'       => caf_params[:bu_head_email],
            'placeholder' => false
          )
        else
          s
        end
      end
    end

    def contract_data_params
      permitted = CafFieldSchema::FIELDS.map { |f| f[:key].to_s }
      params.permit(*permitted).to_h
    end

    def coerce_field_value(field, raw)
      return nil if raw.blank?

      case field[:type]
      when :boolean then ActiveModel::Type::Boolean.new.cast(raw)
      when :integer then raw.to_i
      when :date
        begin
          Date.parse(raw)
        rescue ArgumentError, TypeError
          nil
        end
      when :array   then raw.split(/\r?\n/).map(&:strip).reject(&:blank?)
      else               raw.to_s.strip
      end
    end

    def parse_custom_signatories(raw)
      return nil unless raw.present?

      parsed = JSON.parse(raw)
      unless parsed.is_a?(Array)
        Rails.logger.warn '[IGSIGN] custom_signatories is not an Array, ignoring'
        return nil
      end

      parsed
    rescue JSON::ParserError => e
      Rails.logger.warn "[IGSIGN] custom_signatories parse error: #{e.message}"
      nil
    end
  end
end
