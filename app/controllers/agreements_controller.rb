# frozen_string_literal: true

# IGSIGN — Agreement Wizard: Details → Upload → Review → Send
class AgreementsController < ApplicationController
  skip_authorization_check
  before_action :authenticate_user!
  before_action :set_agreement,
                only: %i[show upload process_upload position save_fields
                         review send_agreement sent caf_preview signing_journey remind destroy
                         confirm_counterparty update_signing_chain
                         withdraw update_counterparty_email replace_document]
  before_action :set_gcip_state, only: :show  # Sprint 4: GCinmyPOCKET

  # ── Index ──────────────────────────────────────────────────────────────────

  def index
    scope = current_account.caf_workflows
                            .includes(:company, :created_by_user, :template,
                                      caf_submission: { caf_stages: { caf_stage_submitters: :submitter } })
                            .recent

    sf = params[:status].to_s.strip
    scope = scope.where(status: sf) if sf.present? && CafWorkflow::STATUSES.include?(sf)

    # Customer / Supplier filter
    cr = params[:relationship].to_s.strip
    scope = scope.commercial_customer if cr == 'customer'
    scope = scope.commercial_supplier if cr == 'supplier'

    # Agreement-type filter (e.g. nda)
    at_filter = params[:agreement_type].to_s.strip
    scope = scope.where(agreement_type: at_filter) if at_filter.present? && CafWorkflow::AGREEMENT_TYPES.key?(at_filter)

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
    @caf_stages             = @agreement.caf_submission
                                &.caf_stages
                                &.includes(caf_stage_submitters: :submitter)
                                &.ordered_by_position
                                &.to_a || []
    @entity_record = IgEntity.find_by(key: @agreement.entity)
    @submission_events = @agreement.caf_submission
                           &.submission_events
                           &.order(event_timestamp: :desc)
                           &.limit(25)
                           &.to_a || []
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
      attach_nda_template!(@agreement) if @agreement.agreement_type == 'nda'
      if @agreement.agreement_type == 'nda'
        redirect_to review_agreement_path(@agreement)
      elsif params[:contract_file].present?
        attach_and_process_inline_upload!(@agreement, params[:contract_file])
      else
        redirect_to upload_agreement_path(@agreement)
      end
    else
      @companies = current_account.companies.alphabetical
      @step = 1
      @new_company_draft = {
        name:                params[:new_company_name].to_s,
        registration_number: params[:new_company_registration_number].to_s,
        contact_name:        params[:new_company_contact_name].to_s,
        contact_email:       params[:new_company_contact_email].to_s,
        domain:              params[:new_company_domain].to_s
      }
      render :new, status: :unprocessable_content
    end
  end

  # ── Step 2 — Upload ────────────────────────────────────────────────────────

  def upload
    @step = 2
  end

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
      documents, = Templates::CreateAttachments.call(template, { files: }, extract_fields: true)
      schema = documents.map { |doc| { attachment_uuid: doc.uuid, name: doc.filename.base } }
      template.update!(schema: schema)
      @agreement.update!(template_id: template.id)

      # Kick off background AI parsing and field detection — silent failure, never blocks upload
      ContractParsingJob.perform_later(@agreement.id)
      FieldDetectionJob.perform_later(template.id)

      # Set up signatories and auto-place signing fields synchronously so the
      # agreement is ready to send without requiring the field-placement step.
      sync_template_submitters!
      auto_place_fields!

      redirect_to review_agreement_path(@agreement),
                  notice: 'Document uploaded — analysing contract. Fields will be auto-filled shortly.'
    rescue StandardError => e
      template.destroy
      Rails.logger.error "[IGSIGN] Upload failed agreement=#{@agreement.id}: #{e.message}"
      user_message =
        if e.message.match?(/LibreOffice|not installed/i)
          'Word documents require LibreOffice which is not available. ' \
          'Please convert your document to PDF and upload again.'
        else
          'Upload failed. Please try again or contact support.'
        end
      redirect_to upload_agreement_path(@agreement), alert: user_message
    end
  end

  # ── Step 2b — Position Fields ─────────────────────────────────────────────

  def position
    unless @agreement.template
      return redirect_to upload_agreement_path(@agreement),
                         alert: 'Upload a document first.'
    end

    sync_template_submitters!
    if @agreement.template.fields.blank?
      placed = ai_detect_fields! || auto_place_fields!
      if placed.zero?
        flash.now[:alert] = 'No signature fields were auto-detected. ' \
                            'Please drag fields onto the document manually.'
      end
    end

    template = @agreement.template
    @detected_fields  = template.fields || []
    @field_counts     = @detected_fields.group_by { |f| f['type'] }.transform_values(&:count)
    @onnx_available   = File.exist?(Templates::ImageToFields::MODEL_PATH)
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

    # Sprint 1 pre-fill support
    @parsed     = @agreement.parsed_contract_data.to_h
    @provenance = @agreement.parsed_data_provenance.to_h
    @prefill_present   = @provenance.any? { |_, v| v == 'ai' }
    @amends_suggestion = @parsed['amends_or_relates_to'].presence

    # Counterparty auto-detect banner: show only when AI found a name AND the handler
    # hasn't filled in the company yet.  Once contracting_party is populated (manual
    # entry or a prior confirm), the banner stays hidden.
    @detected_cp_name  = @parsed['counterparty_name'].presence
    @detected_cp_email = @parsed['counterparty_contact_email'].presence
    @show_cp_detect    = @detected_cp_name.present? &&
                         @agreement.draft? &&
                         @agreement.contracting_party.blank?

    # Signing chain editor data (admin only — loaded for all to avoid extra query on admin check)
    @available_signatories = IgSignatory.active.ordered.map do |s|
      {
        id:         s.id,
        name:       s.full_name,
        email:      s.email,
        role_title: s.role_title.presence || 'Signatory',
        entities:   s.ig_entities.map(&:name).join(', ')
      }
    end
  end

  # ── Send ───────────────────────────────────────────────────────────────────

  def send_agreement
    unless @agreement.draft?
      return redirect_to sent_agreement_path(@agreement)
    end

    result = CafSubmissionCreator.new(@agreement, current_user).call

    if result[:success]
      @agreement.update!(status: 'pending_ig', caf_submission: result[:submission],
                         status_updated_at: Time.current)
      @agreement.company&.sync_agreements_count!
      redirect_to sent_agreement_path(@agreement)
    else
      Rails.logger.error("[IGSIGN] send_agreement failed: #{result[:error]}")
      redirect_to sent_agreement_path(@agreement)
    end
  end

  def sent
    @first_approver_name = (@agreement.signatories&.first&.dig('name') || '').split.first.presence || 'the approver'
  end

  # ── Remind ────────────────────────────────────────────────────────────────

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

  # ── Confirm counterparty (AI-detected) ───────────────────────────────────

  # PATCH /agreements/:id/confirm_counterparty
  # Accepts the handler-confirmed counterparty details from the review page banner.
  # Optionally creates or links a Company record for future search/recall.
  def confirm_counterparty
    cp_name  = params[:contracting_party].to_s.strip
    cp_email = params[:counterparty_email].to_s.strip

    if cp_name.blank?
      return redirect_to review_agreement_path(@agreement), alert: 'Company name is required.'
    end

    updates = { contracting_party: cp_name }
    updates[:counterparty_email] = cp_email if cp_email.present?

    # Find or create a Company record so the counterparty appears in future searches.
    if cp_name.present?
      company = current_account.companies.find_by('LOWER(name) = ?', cp_name.downcase) ||
                current_account.companies.create!(name: cp_name)
      updates[:company_id] = company.id

      # Save contact as a CompanySignatory if we have an email
      if cp_email.present? && company.persisted?
        existing = company.company_signatories.find_by('LOWER(email) = ?', cp_email.downcase)
        unless existing
          company.company_signatories.create!(
            name:  params[:counterparty_contact_name].to_s.strip.presence || cp_name,
            email: cp_email,
            times_signed: 0
          )
        end
      end
    end

    @agreement.update!(updates)
    redirect_to review_agreement_path(@agreement), notice: 'Counterparty details confirmed.'
  rescue StandardError => e
    Rails.logger.error("[IGSIGN] confirm_counterparty error: #{e.message}")
    redirect_to review_agreement_path(@agreement), alert: 'Could not save counterparty details.'
  end

  # ── Update signing chain (admin override) ────────────────────────────────

  # PATCH /agreements/:id/update_signing_chain
  # Allows admins to modify the signing chain before submission.
  # Accepts a JSON array of signatory hashes from the review page editor.
  def update_signing_chain
    unless current_user.role == User::ADMIN_ROLE
      return redirect_to review_agreement_path(@agreement), alert: 'Not authorised.'
    end

    unless @agreement.draft?
      return redirect_to review_agreement_path(@agreement),
                         alert: 'The signing chain cannot be changed once an agreement has been submitted.'
    end

    raw = params[:signatories_json].to_s.strip
    if raw.blank?
      return redirect_to review_agreement_path(@agreement), alert: 'No chain data received.'
    end

    new_chain = JSON.parse(raw)
    unless new_chain.is_a?(Array) && new_chain.all? { |s| s['name'].present? && s['email'].present? }
      return redirect_to review_agreement_path(@agreement), alert: 'Invalid chain — every signatory needs a name and email.'
    end

    # Preserve the counterparty placeholder at the end of the chain
    cp_sig = @agreement.signatories&.find { |s| s['chain_position'] == 'counterparty' }
    chain_without_cp = new_chain.reject { |s| s['chain_position'] == 'counterparty' }
    final_chain = cp_sig ? chain_without_cp + [cp_sig] : chain_without_cp

    @agreement.update!(signatories: final_chain)
    redirect_to review_agreement_path(@agreement), notice: 'Signing chain updated.'
  rescue JSON::ParserError
    redirect_to review_agreement_path(@agreement), alert: 'Could not parse chain data.'
  rescue StandardError => e
    Rails.logger.error("[IGSIGN] update_signing_chain error: #{e.message}")
    redirect_to review_agreement_path(@agreement), alert: 'Could not update signing chain.'
  end

  # ── Withdraw ──────────────────────────────────────────────────────────────────

  # PATCH /agreements/:id/withdraw
  # Cancels a draft or pending-IG agreement.  Preserves the record for audit.
  def withdraw
    unless @agreement.draft? || @agreement.pending_ig?
      return redirect_to agreement_path(@agreement),
                         alert: 'Only draft or pending-approval agreements can be withdrawn.'
    end

    reason = params[:reason].to_s.strip.presence || 'Withdrawn by handler'
    @agreement.update!(status: 'cancelled', status_updated_at: Time.current)
    Rails.logger.info("[IGSIGN] Agreement #{@agreement.id} withdrawn by user #{current_user.id}: #{reason}")
    redirect_to agreements_path, notice: "Agreement withdrawn. Reason: #{reason}"
  rescue StandardError => e
    Rails.logger.error("[IGSIGN] withdraw error for #{@agreement.id}: #{e.message}")
    redirect_to agreement_path(@agreement), alert: 'Could not withdraw the agreement.'
  end

  # ── Update counterparty email ──────────────────────────────────────────────

  # PATCH /agreements/:id/update_counterparty_email
  # Admin only. Updates the counterparty email on both the agreement record and
  # the DocuSeal Submitter so the signing link goes to the corrected address.
  # After updating, admin should use Remind All to resend the invitation.
  def update_counterparty_email
    unless current_user.role == User::ADMIN_ROLE
      return redirect_to agreement_path(@agreement), alert: 'Not authorised.'
    end

    unless @agreement.sent_counterparty?
      return redirect_to agreement_path(@agreement),
                         alert: 'Email can only be corrected while the agreement is with the counterparty.'
    end

    new_email = params[:counterparty_email].to_s.strip
    new_name  = params[:counterparty_name].to_s.strip
    old_email = @agreement.counterparty_email.to_s.strip.downcase

    if new_email.blank? || !new_email.match?(URI::MailTo::EMAIL_REGEXP)
      return redirect_to agreement_path(@agreement), alert: 'A valid email address is required.'
    end

    updates = { counterparty_email: new_email }
    updates[:counterparty_name] = new_name if new_name.present?
    @agreement.update!(updates)

    if @agreement.caf_submission
      sub = @agreement.caf_submission.submitters
                      .find { |s| s.email&.strip&.downcase == old_email }
      if sub
        sub.update!(email: new_email)
        sub.update!(name: new_name) if new_name.present?
      end
    end

    redirect_to agreement_path(@agreement),
                notice: "Counterparty email updated to #{new_email}. Use Remind All to resend the signing invitation."
  rescue StandardError => e
    Rails.logger.error("[IGSIGN] update_counterparty_email error for #{@agreement.id}: #{e.message}")
    redirect_to agreement_path(@agreement), alert: 'Could not update the email. Please try again.'
  end

  # ── Replace document ──────────────────────────────────────────────────────

  # PATCH /agreements/:id/replace_document
  # Draft only. Detaches the current template so the handler can re-upload.
  def replace_document
    unless @agreement.draft?
      return redirect_to agreement_path(@agreement),
                         alert: 'Documents can only be replaced on draft agreements.'
    end

    old_template = @agreement.template
    @agreement.update!(template_id: nil, parsed_contract_data: nil, parsed_data_provenance: nil)
    old_template&.destroy

    redirect_to upload_agreement_path(@agreement),
                notice: 'Document removed. Upload a replacement below.'
  rescue StandardError => e
    Rails.logger.error("[IGSIGN] replace_document error for #{@agreement.id}: #{e.message}")
    redirect_to review_agreement_path(@agreement), alert: 'Could not remove the document.'
  end

  # ── Destroy (draft only) ──────────────────────────────────────────────────

  def destroy
    unless @agreement.draft?
      return redirect_to agreement_path(@agreement),
                         alert: 'Only draft agreements can be deleted.'
    end

    @agreement.template&.destroy
    @agreement.destroy!
    redirect_to agreements_path, notice: 'Draft agreement deleted.'
  end

  # ── CAF Preview ───────────────────────────────────────────────────────────

  def caf_preview
    if @agreement.entity.blank?
      return redirect_to agreement_path(@agreement),
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

  # Looks up the best-match active NDA template for the agreement's entity and
  # attaches it.  Falls back to any account-scoped generic NDA, then to the
  # legacy template name.  If nothing is found, save succeeds and the missing
  # template surfaces as an error at Send time (CafSubmissionCreator).
  def attach_nda_template!(agreement)
    tpl = IgsignTemplateMetadata.entity_nda_for(current_account, agreement.entity)&.template
    tpl ||= current_account.templates.find_by(name: 'IGSIGN NDA Template')
    agreement.update!(template: tpl) if tpl
  end

  def attach_and_process_inline_upload!(agreement, file)
    template = Template.new(
      account: current_account,
      author:  current_user,
      name:    "#{agreement.agreement_type_label} — #{agreement.contracting_party.presence || 'Agreement'}"
    )
    unless template.save
      return redirect_to upload_agreement_path(agreement),
                         alert: 'Could not initialise document record.'
    end

    begin
      documents, = Templates::CreateAttachments.call(template, { files: [file] }, extract_fields: true)
      schema = documents.map { |doc| { attachment_uuid: doc.uuid, name: doc.filename.base } }
      template.update!(schema: schema)
      agreement.update!(template_id: template.id)

      ContractParsingJob.perform_later(agreement.id)
      FieldDetectionJob.perform_later(template.id)

      redirect_to position_agreement_path(agreement),
                  notice: 'Document uploaded. Detecting signing fields — review placements below.'
    rescue StandardError => e
      template.destroy
      Rails.logger.error "[IGSIGN] Inline upload failed agreement=#{agreement.id}: #{e.message}"
      user_message = if e.message.match?(/LibreOffice|not installed/i)
                       'Word documents require LibreOffice which is not available. ' \
                       'Please convert to PDF and try again.'
                     else
                       'Upload failed. Please try again or proceed to the next step to upload.'
                     end
      redirect_to upload_agreement_path(agreement), alert: user_message
    end
  end

  def set_agreement
    @agreement = current_account.caf_workflows.find(params[:id])
  rescue ActiveRecord::RecordNotFound
    redirect_to agreements_path, alert: 'Agreement not found.'
  end

  def agreement_params
    params.require(:agreement).permit(
      :agreement_type, :entity, :ignition_company,
      :commercial_relationship,
      :contracting_party, :counterparty_name, :counterparty_email,
      :company_id, :requestor_name, :requestor_email,
      :high_level_summary, :mandate_description,
      :agreement_purpose, :agreement_value, :agreement_term,
      :payment_terms, :key_risks,
      :currency, :payment_metric_type, :seat_cost, :training_cost, :number_of_seats
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
  # Chain positions that actually sign the agreement document.
  # Internal approvers (bu_head, group_clo, group_cfo, procurement, etc.) sign
  # the CAF only — they must NOT appear as submitters on the agreement template
  # or the position page will demand fields for them on the uploaded document.
  AGREEMENT_SIGNER_POSITIONS = %w[group_signer group_signer_alt].freeze

  def sync_template_submitters!
    sigs = @agreement.signatories.presence || []
    return if sigs.empty?

    # Preserve any UUIDs the template already has (so field assignments survive re-sync)
    existing_by_name = (@agreement.template.submitters || []).index_by { |s| s['name'] }

    # Only group signers sign the actual agreement document.
    # Internal approvers (CLO, CFO, BU Head, Procurement) sign the CAF only.
    agreement_sigs = sigs.select do |sig|
      AGREEMENT_SIGNER_POSITIONS.include?(sig['chain_position'].to_s)
    end

    subs = agreement_sigs.map do |sig|
      role = sig['role'].presence || sig['name']
      existing_by_name[role] || { 'name' => role, 'uuid' => SecureRandom.uuid }
    end

    # Counterparty always signs last on the agreement document
    unless subs.any? { |s| s['name'] == 'Counterparty' }
      subs << (existing_by_name['Counterparty'] || { 'name' => 'Counterparty', 'uuid' => SecureRandom.uuid })
    end

    @agreement.template.update!(submitters: subs) if subs != @agreement.template.submitters
  end

  # Populates the agreement template with auto-placed signature / name / date
  # blocks for each signatory party — one row per party stacked vertically.
  # Only runs when the template has no fields yet, so manual edits are preserved.
  #
  # Returns the number of fields placed (0 on any failure path so callers can
  # detect and surface a user-facing warning).
  # Sprint 2: AI field detection synchronous fallback (runs in position action
  # if FieldDetectionJob hasn't completed yet). Returns field count or nil if
  # ONNX model absent (caller falls back to auto_place_fields!).
  def ai_detect_fields!
    return nil unless File.exist?(Templates::ImageToFields::MODEL_PATH)

    template = @agreement.template
    return nil if template.fields.present?

    FieldDetectionJob.new.perform(template.id)
    template.reload
    (template.fields || []).length
  rescue StandardError => e
    Rails.logger.warn("[IGSIGN] ai_detect_fields! error: #{e.message}")
    nil
  end

  # Sprint 4: GCinmyPOCKET — expose @gcip_enabled and @gcip_workflow_id.
  # Panel shown only for Stage 0/1 signers when AI_API_KEY is set.
  def set_gcip_state
    @gcip_enabled    = false
    @gcip_workflow_id = nil
    return unless ENV['AI_API_KEY'].present?
    return unless @agreement&.caf_submission

    stage = CafStage.joins(:caf_stage_submitters)
                    .find_by(submission: @agreement.caf_submission,
                             caf_stage_submitters: { submitter_id: nil })
    # Stage gate is enforced in ContractChatService; this just pre-checks
    @gcip_enabled     = true
    @gcip_workflow_id = @agreement.id
  rescue StandardError => e
    Rails.logger.warn("[IGSIGN] set_gcip_state failed: #{e.message}")
    @gcip_enabled = false
  end

  def auto_place_fields!
    template = @agreement.template
    return 0 if (template.fields || []).any?

    att_uuid = template.schema_documents.first&.uuid
    unless att_uuid
      Rails.logger.warn("[IGSIGN] auto_place_fields!: no schema document for template #{template.id}")
      return 0
    end

    subs = template.submitters || []
    if subs.empty?
      Rails.logger.warn("[IGSIGN] auto_place_fields!: no submitters for template #{template.id}")
      return 0
    end

    fields = subs.each_with_index.flat_map do |sub, idx|
      build_auto_fields(sub['uuid'], sub['name'], att_uuid, idx)
    end

    return 0 unless fields.any?

    template.update!(fields: fields)
    fields.length
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

    if @agreement.ig_complete?
      return {
        name:       'IGSIGN',
        role:       'IG approval complete — activating counterparty signing',
        email:      nil,
        invited_at: nil,
        days:       0,
        transitioning: true
      }
    end

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
