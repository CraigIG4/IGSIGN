# frozen_string_literal: true

class SubmitFormController < ApplicationController
  layout 'form'

  around_action :with_browser_locale, only: %i[show completed success delegated]
  skip_before_action :authenticate_user!
  skip_authorization_check

  before_action :load_submitter, only: %i[show update completed]
  before_action :maybe_redirect_delegated, only: %i[show completed]
  before_action :maybe_render_locked_page, only: :show
  before_action :maybe_require_link_2fa, only: %i[show]
  before_action :set_gcip_state, only: :show

  CONFIG_KEYS = [].freeze

  def show
    submission = @submitter.submission

    return render :email_2fa unless Submitters::AuthorizedForForm.pass_email_2fa?(@submitter, request)
    return redirect_to completed_submit_form_path(@submitter.slug) if @submitter.completed_at?

    @form_configs = Submitters::FormConfigs.call(@submitter, CONFIG_KEYS)

    return render :awaiting if (@form_configs[:enforce_signing_order] ||
                                submission.template&.preferences&.dig('submitters_order') == 'preserved') &&
                               !Submitters.current_submitter_order?(@submitter)

    # IGSIGN: For CAF Stage 2 (counterparty) submitters, narrow the in-memory
    # template_schema to exclude internal-only documents before preloading.
    # This ensures filtered_conditions_schema and schema_documents both operate
    # on the restricted set without touching the database record.
    maybe_filter_caf_schema_for_counterparty(@submitter, submission)

    Submissions.preload_with_pages(submission)

    Submitters::MaybeUpdateDefaultValues.call(@submitter, current_user)

    @attachments_index = build_attachments_index(submission)

    return unless @form_configs[:prefill_signature]

    if (user_signature = UserConfigs.load_signature(current_user))
      @signature_attachment = ActiveStorage::Attachment.find_or_create_by!(
        blob_id: user_signature.blob_id,
        name: 'attachments',
        record: @submitter
      )
    end

    @signature_attachment ||=
      Submitters::MaybeAssignDefaultBrowserSignature.call(@submitter, params, cookies, @attachments_index.values)

    @attachments_index[@signature_attachment.uuid] = @signature_attachment if @signature_attachment
  end

  def update
    unless Submitters::AuthorizedForForm.call(@submitter, current_user, request)
      return render json: { error: I18n.t('verification_required_refresh_the_page_and_pass_2fa') },
                    status: :unprocessable_content
    end

    if @submitter.completed_at?
      return render json: { error: I18n.t('form_has_been_completed_already') }, status: :unprocessable_content
    end

    if @submitter.submission.template&.archived_at? || @submitter.submission.archived_at?
      return render json: { error: I18n.t('form_has_been_archived') }, status: :unprocessable_content
    end

    if @submitter.submission.expired?
      return render json: { error: I18n.t('form_has_been_expired') }, status: :unprocessable_content
    end

    if @submitter.declined_at?
      return render json: { error: I18n.t('form_has_been_declined') },
                    status: :unprocessable_content
    end

    Submitters::SubmitValues.call(@submitter, params, request)

    head :ok
  rescue Submitters::SubmitValues::RequiredFieldError => e
    Rollbar.warning("Required field #{@submitter.id}: #{e.message}") if defined?(Rollbar)

    render json: { field_uuid: e.message }, status: :unprocessable_content
  rescue Submitters::SubmitValues::ValidationError => e
    Rollbar.warning("Validation error #{@submitter.id}: #{e.message}") if defined?(Rollbar)

    render json: { error: e.message }, status: :unprocessable_content
  end

  def completed
    raise ActionController::RoutingError, I18n.t('not_found') if @submitter.account.archived_at?

    return if Submitters::AuthorizedForForm.call(@submitter, current_user, request)

    redirect_to submit_form_path(params[:submit_form_slug])
  end

  def success; end

  def delegated
    submitter_version = SubmitterVersion.find_by!(slug: params[:slug] || params[:submit_form_slug])

    @submitter = submitter_version.submitter
  end

  private

  def maybe_require_link_2fa
    return if Submitters::AuthorizedForForm.pass_link_2fa?(@submitter, current_user, request)

    redirect_to start_form_path(@submitter.submission.template.slug)
  end

  def maybe_render_locked_page
    return render :archived if @submitter.submission.template&.archived_at? ||
                               @submitter.submission.archived_at? ||
                               @submitter.account.archived_at?
    return render :expired if @submitter.submission.expired?

    render :declined if @submitter.declined_at?
  end

  def maybe_redirect_delegated
    return if @submitter

    submitter_version = SubmitterVersion.find_by!(slug: params[:slug] || params[:submit_form_slug])

    submitter_version.submitter.submission_events.find_by!(event_type: :delegate_form)

    redirect_to delegated_submit_form_path(submitter_version.slug)
  end

  def load_submitter
    @submitter = Submitter.find_by(slug: params[:slug] || params[:submit_form_slug])
  end

  def build_attachments_index(submission)
    ActiveStorage::Attachment.where(record: submission.submitters, name: :attachments)
                             .preload(:blob).index_by(&:uuid)
  end

  # Mutates submission.template_schema in memory (does NOT persist) to remove
  # internal-only document entries for counterparty (Stage 2+) submitters.
  # No-ops for non-CAF submissions and Stage 1 submitters.
  # IGSIGN GCinmyPOCKET — sets @gcip_enabled and @gcip_workflow_id.
  # Panel is shown only for Stage 0/1 signers (position < 2) when AI_API_KEY is set.
  # Stage 2 (counterparty) gets a clean signing form with no chatbot.
  def set_gcip_state
    @gcip_enabled    = false
    @gcip_workflow_id = nil
    return unless ENV['AI_API_KEY'].present?
    return unless @submitter&.submission

    stage = CafStage.joins(:caf_stage_submitters)
                    .find_by(submission: @submitter.submission,
                             caf_stage_submitters: { submitter_id: @submitter.id })
    return unless stage&.position&.< 2

    @gcip_enabled     = true
    @gcip_workflow_id = CafWorkflow.find_by(caf_submission_id: @submitter.submission_id)&.id
  rescue StandardError => e
    Rails.logger.warn("[IGSIGN] set_gcip_state failed: #{e.message}")
    @gcip_enabled = false
  end

  def maybe_filter_caf_schema_for_counterparty(submitter, submission)
    stage = CafStage.joins(:caf_stage_submitters)
                    .find_by(submission: submission,
                             caf_stage_submitters: { submitter_id: submitter.id })

    return unless stage&.position&.positive?

    internal_uuids = submission.caf_stage_documents
                               .where(internal_only: true)
                               .pluck(:document_uuid)
                               .to_set
    return if internal_uuids.empty?

    full_schema = submission.template_schema.presence ||
                  submission.template&.schema ||
                  []

    submission.template_schema = full_schema.reject do |item|
      internal_uuids.include?(item['attachment_uuid'])
    end
  end
end
