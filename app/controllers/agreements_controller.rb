# frozen_string_literal: true

# IGSIGN — Agreement Wizard: Details → Upload → Review → Send
class AgreementsController < ApplicationController
  skip_authorization_check
  before_action :authenticate_user!
  before_action :set_agreement, only: %i[show upload process_upload position save_fields review send_agreement caf_preview signing_journey remind]

  # ── Index ──────────────────────────────────────────────────────────────────

  def index
    scope = current_account.caf_workflows
                            .includes(:company, :created_by_user, :template,
                                      caf_submission: { caf_stages: { caf_stage_submitters: :submitter } })
                            .recent

    sf = params[:status].to_s.strip
    scope = scope.where(status: sf) if sf.present? && CafWorkflow::STATUSES.include?(sf)

    @agreements = scope
    @stats = {
      total:   current_account.caf_workflows.count,
      draft:   current_account.caf_workflows.draft.count,
      active:  current_account.caf_workflows.active.count,
      complete: current_account.caf_workflows.complete.count,
      overdue: current_account.caf_workflows.overdue.count
    }
  end

  # ── Show ───────────────────────────────────────────────────────────────────

  def show
    @signatories            = @agreement.signatories || []
    @submitter_statuses     = build_submitter_statuses(@agreement)
    @counterparty_signatory = load_counterparty_signatory
    @current_holder         = load_current_holder
  end

  # ── Signing Journey fragment (Turbo Frame polling endpoint) ────────────

  def signing_journey
    @signatories            = @agreement.signatories || []
    @submitter_statuses     = build_submitter_statuses(@agreement)
    @counterparty_signatory = load_counterparty_signatory
    render layout: false
  end

  # ── Step 1 — Details ───────────────────────────────────────────────────────

  def new
    @agreement = CafWorkflow.new(
      requestor_name: current_user.full_name,
      requestor_email: current_user.email
    )

    # Pre-select agreement type from template metadata when coming from the library
    if params[:template_id].present?
      @preselected_template_id = params[:template_id].to_i
      tmpl_meta = IgsignTemplateMetadata.joins(:template)
                    .where(templates: { account_id: current_account.id })
                    .find_by(template_id: @preselected_template_id)
      @agreement.agreement_type = tmpl_meta.kind if tmpl_meta
    end

    @companies = current_account.companies.alphabetical
    @step = 1
  end

  def create
    @agreement = CafWorkflow.new(agreement_params)
    @agreement.account = current_account
    @agreement.created_by_user = current_user
    @agreement.status = 'draft'

    # Associate template if pre-selected from the library (validated to account scope)
    if params[:template_id].present?
      tmpl = current_account.templates.find_by(id: params[:template_id])
      @agreement.template_id = tmpl.id if tmpl
    end

    build_inline_company(@agreement, params)
    autofill_from_company!(@agreement)

    @agreement.auto_assign_signatories!

    if @agreement.save
      if @agreement.agreement_type == 'nda'
        # NDA path: bind the standing NDA template (if configured) and skip upload.
        # If the template hasn't been created yet the agreement still saves; the
        # missing-template error surfaces at Send time via CafSubmissionCreator.
        nda_tpl = current_account.templates.find_by(name: 'IGSIGN NDA Template')
        @agreement.update!(template: nda_tpl) if nda_tpl
        redirect_to review_agreement_path(@agreement)
      else
        redirect_to upload_agreement_path(@agreement)
      end
    else
      @companies = current_account.companies.alphabetical
      @step = 1
      render :new, status: :unprocessable_content
    end
  end

  # ── Step 2 — Upload ────────────────────────────────────────────────────────

  def upload
    @step = 2
  end

  # rubocop:disable Metrics/MethodLength
  def process_upload
    files = Array(params[:files]).reject(&:blank?)
    if files.empty?
      return redirect_to upload_agreement_path(@agreement),
                         alert: 'Please choose at least one document to upload.'
    end

    template = Template.new(
      account: current_account,
      author: current_user,
      name: "#{@agreement.agreement_type_label} — #{@agreement.contracting_party.presence || 'Agreement'}"
    )

    unless template.save
      return redirect_to upload_agreement_path(@agreement),
                         alert: 'Could not initialise document record.'
    end

    begin
      Templates::CreateAttachments.call(template, { files: }, extract_fields: true)
      @agreement.update!(template_id: template.id)

      field_count = template.reload.fields&.length || 0
      notice = build_field_detection_notice(field_count)
      redirect_to position_agreement_path(@agreement), notice: notice
    rescue StandardError => e
      template.destroy
      Rails.logger.error "[IGSIGN] Upload failed agreement=#{@agreement.id}: #{e.message}"
      user_message =
        if e.message.match?(/LibreOffice|not installed/i)
          'Word documents require LibreOffice which is not available. Please convert your document to PDF and upload again.'
        else
          'Upload failed. Please try again or contact support.'
        end
      redirect_to upload_agreement_path(@agreement), alert: user_message
    end
  end
  # rubocop:enable Metrics/MethodLength

  # ── Step 2b — Position Fields ─────────────────────────────────────────────

  # rubocop:disable Metrics/MethodLength
  def position
    unless @agreement.template
      return redirect_to upload_agreement_path(@agreement),
                         alert: 'Upload a document first.'
    end

    sync_template_submitters!
    auto_place_fields! if @agreement.template.fields.blank?

    template = @agreement.template
    ActiveRecord::Associations::Preloader.new(
      records: [template],
      associations: [{ schema_documents: [:blob, { preview_images_attachments: :blob }] }]
    ).call

    @template_data =
      template.as_json.merge(
        documents: template.schema_documents.as_json(
          methods: %i[metadata signed_key],
          include: { preview_images: { methods: %i[url metadata filename] } }
        )
      ).to_json

    render layout: 'plain'
  end
  # rubocop:enable Metrics/MethodLength

  def save_fields
    unless @agreement.template
      return redirect_to upload_agreement_path(@agreement),
                         alert: 'Upload a document first.'
    end

    errors = field_coverage_errors(@agreement.template)
    if errors.any?
      return redirect_to position_agreement_path(@agreement),
                         alert: "Place at least one signature field for: #{errors.join(', ')}"
    end

    redirect_to review_agreement_path(@agreement)
  end

  # ── Step 3 — Review ────────────────────────────────────────────────────────

  def review
    @step = 3
    @signatories   = @agreement.signatories || []
    @template_docs = @agreement.template&.documents&.attachments&.includes(:blob) || []

    @counterparty_signatory = load_counterparty_signatory
  end

  # ── Send ───────────────────────────────────────────────────────────────────

  def send_agreement
    unless @agreement.draft?
      return redirect_to agreement_path(@agreement),
                         alert: 'This agreement has already been submitted.'
    end

    if @agreement.counterparty_email.blank?
      return redirect_to review_agreement_path(@agreement),
                         alert: "Counterparty email is required before sending. " \
                                "Please add the counterparty's email address."
    end

    result = CafSubmissionCreator.new(@agreement, current_user).call

    if result[:success]
      @agreement.update!(status: 'pending_ig', caf_submission: result[:submission],
                         status_updated_at: Time.current)
      @agreement.company&.sync_agreements_count!
      redirect_to agreement_path(@agreement),
                  notice: 'Agreement submitted. Internal signatories have been notified.'
    else
      redirect_to review_agreement_path(@agreement),
                  alert: "Could not send: #{result[:error]}"
    end
  end

  # ── Remind ────────────────────────────────────────────────────────────────

  # rubocop:disable Metrics/MethodLength
  # POST /agreements/:id/remind
  # Queues immediate reminder emails for all unsigned submitters in the current
  # active stage.  Resets the reminder ladder so day-2/5/9/14 restarts from now.
  # Only the agreement's requestor (or any authenticated user with access) can
  # trigger this — workflow ownership is enforced by set_agreement scoping to
  # current_account.
  def remind
    submission = @agreement.caf_submission
    unless submission
      return redirect_to agreement_path(@agreement),
                         alert: 'Cannot send reminders — this agreement has not been submitted yet.'
    end

    active_stage = submission.caf_stages.active.ordered_by_position.first
    unless active_stage
      return redirect_to agreement_path(@agreement),
                         alert: 'No active signing stage found — all parties may have already signed.'
    end

    count = 0
    active_stage.caf_stage_submitters
                .not_completed
                .includes(:submitter)
                .find_each do |css|
      next if css.submitter.completed_at.present?

      ReminderMailer.signing_reminder(css, days_since_invite(css)).deliver_later
      css.update_columns(reminder_sent_at: Time.current)
      count += 1
    end

    if count.positive?
      redirect_to agreement_path(@agreement),
                  notice: "Reminders sent to #{count} pending #{count == 1 ? 'signatory' : 'signatories'}."
    else
      redirect_to agreement_path(@agreement),
                  alert: 'No pending signatories to remind — everyone has already signed.'
    end
  end
  # rubocop:enable Metrics/MethodLength

  # ── CAF Preview ───────────────────────────────────────────────────────────

  def caf_preview
    if @agreement.entity.blank?
      return redirect_to @agreement,
                         alert: 'Cannot preview CAF: entity not selected.'
    end

    pdf_path = CafPdfGenerator.new(@agreement).generate
    send_data File.read(pdf_path), filename: "caf_#{@agreement.id}_preview.pdf",
                                   type: 'application/pdf', disposition: 'inline'
  rescue StandardError => e
    Rails.logger.error "[IGSIGN] CAF preview failed agreement=#{@agreement.id}: #{e.message}"
    redirect_to review_agreement_path(@agreement),
                alert: 'CAF preview is not available yet. ' \
                       'Ensure LibreOffice is installed and the entity is selected.'
  ensure
    File.delete(pdf_path) if pdf_path && File.exist?(pdf_path)
  end

  # ── Recent signatories AJAX ────────────────────────────────────────────────

  def recent_signatories
    company = current_account.companies.find_by(id: params[:company_id])
    return render json: { signatories: [], smart_default_id: nil } unless company

    sigs = company.recent_signatories(limit: 5).map do |sig|
      {
        id:              sig.id,
        name:            sig.name,
        email:           sig.email,
        role_title:      sig.role_title.presence || '',
        authority_basis: sig.authority_basis.presence || '',
        times_signed:    sig.times_signed,
        last_seen_label: sig.last_seen_label
      }
    end

    render json: {
      signatories:      sigs,
      smart_default_id: company.smart_default_signatory&.id
    }
  end

  # ── AJAX company search ────────────────────────────────────────────────────

  def search_companies
    q = params[:q].to_s.strip
    companies = if q.present?
                  current_account.companies.search(q).limit(8)
                else
                  current_account.companies.alphabetical.limit(8)
                end

    render json: companies.map { |c|
      {
        id: c.id,
        name: c.name,
        contact_name: c.primary_contact_name,
        contact_email: c.primary_contact_email,
        domain: c.domain,
        count: c.agreements_count
      }
    }
  end

  private

  def set_agreement
    @agreement = current_account.caf_workflows.find(params[:id])
  rescue ActiveRecord::RecordNotFound
    redirect_to agreements_path, alert: 'Agreement not found.'
  end

  def agreement_params
    params.require(:agreement).permit(
      :agreement_type, :entity, :ignition_company,
      :contracting_party, :counterparty_name, :counterparty_email,
      :company_id, :requestor_name, :requestor_email,
      :high_level_summary, :mandate_description,
      :agreement_purpose, :agreement_value, :agreement_term,
      :payment_terms, :key_risks
    )
  end

  # Creates or finds a company record from inline form fields and assigns it
  # to the agreement when the user types a new company name rather than
  # selecting an existing one.
  def build_inline_company(agreement, form_params)
    return unless form_params[:new_company_name].present?

    co = current_account.companies.find_or_initialize_by(name: form_params[:new_company_name].strip)
    co.assign_attributes(
      primary_contact_name: form_params[:new_company_contact_name].to_s.strip,
      primary_contact_email: form_params[:new_company_contact_email].to_s.strip,
      domain: form_params[:new_company_domain].to_s.strip
    )
    co.save
    agreement.company = co
  end

  # Copies the IGSIGN CAF Template's submitter UUIDs to the agreement template
  # so that user-placed fields reference UUIDs the submission will later bind
  # Submitter records to.  Without this, the agreement fields appear on the
  # correct pages but are unassigned (no submitter owns them).
  def sync_template_submitters!
    caf_tpl = @agreement.account.templates.find_by(name: 'IGSIGN CAF Template')
    return unless caf_tpl

    caf_subs_by_role = (caf_tpl.submitters || []).index_by { |s| s['name'] }

    subs = (@agreement.signatories || []).filter_map do |sig|
      matched = caf_subs_by_role[sig['role']]
      next unless matched

      { 'name' => sig['role'], 'uuid' => matched['uuid'] }
    end

    cp_sub = caf_subs_by_role['Counterparty']
    subs << { 'name' => 'Counterparty', 'uuid' => cp_sub['uuid'] } if cp_sub

    @agreement.template.update!(submitters: subs) if subs != @agreement.template.submitters
  end

  # Populates the agreement template with auto-placed signature / name / date
  # blocks for each signatory party — one row per party stacked vertically.
  # Only runs when the template has no fields yet, so manual edits are preserved.
  def auto_place_fields!
    template = @agreement.template
    att_uuid = template.schema_documents.first&.uuid
    return unless att_uuid

    subs   = template.submitters || []
    fields = subs.each_with_index.flat_map do |sub, idx|
      build_auto_fields(sub['uuid'], sub['name'], att_uuid, idx)
    end

    template.update!(fields: fields) if fields.any?
  end

  # Builds three auto-placed fields (signature, full-name, date) for one party.
  # Parties are stacked vertically starting at y=0.72 with a 0.07 step.
  # Signature block occupies left third, name centre, date right.
  def build_auto_fields(sub_uuid, sub_name, att_uuid, idx)
    y = 0.72 + (idx * 0.07)
    [
      { 'uuid' => SecureRandom.uuid, 'submitter_uuid' => sub_uuid,
        'name' => "#{sub_name} Signature", 'type' => 'signature', 'required' => true,
        'preferences' => {},
        'areas' => [{ 'x' => 0.05, 'y' => y, 'w' => 0.25, 'h' => 0.05,
                      'page' => 0, 'attachment_uuid' => att_uuid }] },
      { 'uuid' => SecureRandom.uuid, 'submitter_uuid' => sub_uuid,
        'name' => "#{sub_name} Full Name", 'type' => 'text', 'required' => true,
        'preferences' => {},
        'areas' => [{ 'x' => 0.35, 'y' => y, 'w' => 0.30, 'h' => 0.05,
                      'page' => 0, 'attachment_uuid' => att_uuid }] },
      { 'uuid' => SecureRandom.uuid, 'submitter_uuid' => sub_uuid,
        'name' => "#{sub_name} Date", 'type' => 'date', 'required' => true,
        'preferences' => { 'format' => 'DD/MM/YYYY' },
        'areas' => [{ 'x' => 0.70, 'y' => y, 'w' => 0.25, 'h' => 0.05,
                      'page' => 0, 'attachment_uuid' => att_uuid }] }
    ]
  end

  # Returns the names of any submitter parties that lack at least one
  # signature-type field in the template.  Used to gate the Continue button.
  def field_coverage_errors(template)
    subs   = template.submitters || []
    fields = template.fields || []
    signed_uuids = fields.select { |f| f['type'] == 'signature' }
                         .map { |f| f['submitter_uuid'] }.to_set

    subs.filter_map { |sub| sub['name'] unless signed_uuids.include?(sub['uuid']) }
  end

  # Returns a hash of email.downcase => Submitter for the CAF submission's
  # submitters, used to derive per-signatory signing status.
  def build_submitter_statuses(agreement)
    return {} unless agreement.caf_submission

    agreement.caf_submission.submitters
             .index_by { |s| s.email.to_s.strip.downcase }
  rescue StandardError
    {}
  end

  # Loads the memorised CompanySignatory for the agreement's counterparty
  # email (if a company is linked). Reused across show, signing_journey, review.
  def load_counterparty_signatory
    return unless @agreement.company && @agreement.counterparty_email.present?

    @agreement.company.company_signatories
              .find_by(email: @agreement.counterparty_email.strip.downcase)
  end

  # Loads the current holder hash for the show page status card:
  # { name:, role:, email:, invited_at:, days: }
  # Returns nil when the workflow is draft/complete or no active stage is found.
  def load_current_holder
    return nil if @agreement.draft? || @agreement.complete? || @agreement.cancelled?
    return nil unless @agreement.caf_submission

    if @agreement.sent_counterparty?
      return {
        name:       @agreement.counterparty_name.presence || @agreement.contracting_party || 'Counterparty',
        role:       'Counterparty Signatory',
        email:      @agreement.counterparty_email,
        invited_at: nil,
        days:       @agreement.days_in_current_stage
      }
    end

    active_stage = @agreement.caf_submission.caf_stages.active.ordered_by_position.first
    return nil unless active_stage

    css = active_stage.caf_stage_submitters
                      .not_completed
                      .includes(:submitter)
                      .ordered
                      .first
    return nil unless css

    {
      name:       css.submitter.name,
      role:       css.role,
      email:      css.submitter.email,
      invited_at: css.invited_at,
      days:       css.invited_at ? ((Time.current - css.invited_at) / 1.day).to_i : @agreement.days_in_current_stage
    }
  end

  # Returns the number of whole days since a CafStageSubmitter's invite was sent.
  # Falls back to 0 if invited_at is blank.
  def days_since_invite(css)
    return 0 unless css.invited_at

    ((Time.current - css.invited_at) / 1.day).to_i
  end

  # Returns a user-facing flash notice summarising the auto-field-detection
  # result after a document upload. Zero fields detected prompts manual
  # placement; one or more fields confirms the count and asks for review.
  def build_field_detection_notice(field_count)
    if field_count.zero?
      'No signature fields were auto-detected. ' \
        'Please place fields manually by dragging them onto the document below.'
    else
      plural = field_count == 1 ? 'field' : 'fields'
      "#{field_count} #{plural} auto-detected. Review and adjust positions before sending."
    end
  end

  # Fills blank counterparty fields on the agreement from the associated
  # company record so the user doesn't have to re-enter known contact details.
  def autofill_from_company!(agreement)
    co = agreement.company
    return unless co

    agreement.contracting_party = co.name if agreement.contracting_party.blank?
    agreement.counterparty_name = co.primary_contact_name if agreement.counterparty_name.blank?
    agreement.counterparty_email = co.primary_contact_email if agreement.counterparty_email.blank?
  end
end
