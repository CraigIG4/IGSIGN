# frozen_string_literal: true

# IGSIGN — Creates a DocuSeal Submission for the internal CAF signing phase.
#
# Document model:
#   Each CAF submission carries two types of documents, tracked in CafStageDocument:
#
#   1. CAF summary PDF (internal_only: true)
#      Generated from CafPdfGenerator.  Stage 1 signatories see it; the
#      counterparty never does.  The record is preserved for audit.
#
#   2. Uploaded agreement (internal_only: false)
#      The contract being executed.  Visible to all stages.
#
#   At Stage 1 → Stage 2 transition, CafStage#complete! sets stripped: true on
#   internal_only documents as an informational audit marker.  Visibility
#   filtering is enforced by Submission#documents_for(submitter) and
#   SubmitFormController (schema override).
#
# After all IG signatories complete, CafCompletionHandler fires to activate
# Stage 2 (counterparty).
class CafSubmissionCreator
  # Maps CAF signatory roles to the corresponding slot name in the IGSIGN CAF
  # Template.  Roles absent from this map have no positioned fields on the
  # signing-page PDF and legitimately receive random UUIDs (DocuSeal will still
  # prompt them to sign, just without pre-placed field boxes).
  TEMPLATE_SLOT_FOR_ROLE = {
    'BU Head'          => 'BU Head',
    'Finance Director' => 'Finance Director',
    'CEO'              => 'CEO',
    'COO'              => 'CEO'   # COO signs in the CEO block when the CEO is absent
  }.freeze

  # IgEntitySignatory positions that belong to the parallel Stage 0 internal-approval phase.
  INTERNAL_POSITIONS = %w[
    bu_head bu_cfo bu_cfo_alternate group_clo group_cfo procurement approver_only
  ].freeze

  # IgEntitySignatory positions that run as sequential group-signer stages (Stage 1+).
  # Order matters: group_signer is always invited before group_signer_alt.
  SEQUENTIAL_POSITIONS = %w[group_signer group_signer_alt].freeze

  def initialize(caf, initiated_by_user)
    @caf  = caf
    @user = initiated_by_user
  end

  def call
    unresolved = unresolved_signatories
    if unresolved.any?
      unresolved_roles = unresolved.pluck('role').join(', ')
      return { success: false, error: "Please assign all signatories (unresolved: #{unresolved_roles})" }
    end

    submission = build_submission
    attach_signatories(submission)
    attach_stages(submission)
    attach_caf_pdf_document(submission)

    if @caf.agreement_type == 'nda'
      # NDA path: dynamically generate the agreement PDF — no static template document needed.
      attach_nda_agreement_document(submission)
    else
      attach_contract_document(submission)
      merge_agreement_template_fields!(submission)
    end

    extend_submission_schema(submission)

    submission.caf_stages.ordered_by_position.first&.activate!

    { success: true, submission: submission }
  rescue StandardError => e
    Rails.logger.error("CafSubmissionCreator failed: #{e.message}\n#{e.backtrace.first(5).join("\n")}")
    { success: false, error: e.message }
  end

  private

  def unresolved_signatories
    @caf.signatories.select { |s| s['placeholder'] && s['email'].blank? }
  end

  def build_submission
    # All agreement types use the generic CAF Template which provides submitter
    # slots and any pre-positioned signing-page fields.  The agreement document
    # itself is attached separately:
    #   - NDA: generated dynamically by NdaAgreementGenerator (attach_nda_agreement_document)
    #   - Others: blobs from @caf.template re-attached by attach_contract_document
    template = find_or_create_caf_template

    Submission.create!(
      account: @caf.account,
      template: template,
      created_by_user: @user,
      source: 'api',
      submitters_order: 'random',
      name: submission_name
    )
  end

  def attach_signatories(submission)
    # Map template submitter UUIDs by slot name so each Submitter record gets
    # the UUID the template fields are already bound to.  Without this, fields
    # appear in the signing form but are owned by a UUID that matches no actual
    # submitter, rendering them as unassigned blanks.
    #
    # TEMPLATE_SLOT_FOR_ROLE handles aliases (e.g. COO → CEO slot) so that a
    # COO signatory is assigned to the CEO signature block on the PDF.
    tpl_sub_by_name = (submission.template&.submitters || []).index_by { |s| s['name'] }

    @caf.signatories.each_with_index do |sig, idx|
      slot = TEMPLATE_SLOT_FOR_ROLE[sig['role']]
      uuid = (slot && tpl_sub_by_name.dig(slot, 'uuid')) || SecureRandom.uuid

      submission.submitters.create!(
        account:  @caf.account,
        name:     sig['name'],
        email:    sig['email'],
        uuid:     uuid,
        slug:     SecureRandom.base58(14),
        metadata: {
          'caf_role'       => sig['role'],
          'caf_position'   => idx,
          'chain_position' => sig['chain_position'].to_s
        }
      )
    end
  end

  def attach_stages(submission)
    # resolve_for is the preferred lookup; fall back to legacy document_type lookup.
    matrix = CafApprovalMatrix.resolve_for(
      @caf.account,
      agreement_type:          @caf.agreement_type,
      entity:                  @caf.entity,
      commercial_relationship: @caf.commercial_relationship
    ) || CafApprovalMatrix.for(@caf.account, caf_type_for_matrix)

    if matrix
      matrix.build_stages_for(submission).each(&:save!)
    else
      build_default_stages(submission)
    end

    # Guard: an empty matrix (stages_config: []) produces no stage records,
    # which means Stage 0 activate! silently no-ops and the workflow hangs at
    # pending_ig with nobody invited.  Surface this as a hard error at Send
    # time so the sender sees a clear message instead of a silent hang.
    return unless submission.caf_stages.reload.empty?

    raise StandardError,
          "No approval stages could be built for this #{@caf.agreement_type_label} agreement. " \
          'Check the CafApprovalMatrix configuration in Admin → Approval Matrices.'
  end

  # Generates the CAF summary PDF and attaches it to the submission as an
  # internal-only document.  Failures are logged and swallowed — the
  # signing flow proceeds even if LibreOffice is unavailable.
  def attach_caf_pdf_document(submission)
    pdf_path = nil
    pdf_path = CafPdfGenerator.new(@caf).generate

    blob = ActiveStorage::Blob.create_and_upload!(
      io:           File.open(pdf_path),
      filename:     "caf_#{@caf.id}_summary.pdf",
      content_type: 'application/pdf'
    )
    submission.documents.attach(blob)
    attachment = ActiveStorage::Attachment.find_by!(
      record_type: 'Submission', record_id: submission.id,
      name: 'documents', blob_id: blob.id
    )

    CafStageDocument.create!(
      submission:    submission,
      document_uuid: attachment.uuid,
      document_name: blob.filename.to_s,
      internal_only: true
    )

    process_document_async(attachment)
  rescue StandardError => e
    Rails.logger.error("[CafSubmissionCreator] CAF PDF generation failed for #{@caf.id}: #{e.message}")
  ensure
    File.delete(pdf_path) if pdf_path && File.exist?(pdf_path)
  end

  # Registers externally-visible documents (internal_only: false) on the submission.
  # Only called for non-NDA workflows (NDA documents are generated dynamically by
  # attach_nda_agreement_document instead).
  #
  # Blobs from @caf.template are re-attached to the submission as new
  # ActiveStorage::Attachment records (new UUIDs).  CafStageDocument entries
  # reference those new submission-level UUIDs.
  def attach_contract_document(submission)
    template = @caf.template
    return unless template

    template.documents.attachments.each do |src_attach|
      blob = src_attach.blob
      submission.documents.attach(blob)
      attachment = ActiveStorage::Attachment.find_by!(
        record_type: 'Submission', record_id: submission.id,
        name: 'documents', blob_id: blob.id
      )

      CafStageDocument.create!(
        submission:    submission,
        document_uuid: attachment.uuid,
        document_name: blob.filename.to_s,
        internal_only: false
      )
    end
  end

  # Generates the NDA agreement PDF via NdaAgreementGenerator and attaches it
  # to the submission as a counterparty-visible (internal_only: false) document.
  # This replaces the former static "IGSIGN NDA Template" approach, allowing
  # party names and purpose to be embedded dynamically in every agreement.
  #
  # Failures are logged and swallowed so the signing flow degrades gracefully
  # if LibreOffice is unavailable (signatories will sign the CAF only).
  def attach_nda_agreement_document(submission)
    pdf_path = nil
    pdf_path = NdaAgreementGenerator.new(@caf).generate

    blob = ActiveStorage::Blob.create_and_upload!(
      io:           File.open(pdf_path),
      filename:     "nda_agreement_#{@caf.id}.pdf",
      content_type: 'application/pdf'
    )
    submission.documents.attach(blob)
    attachment = ActiveStorage::Attachment.find_by!(
      record_type: 'Submission', record_id: submission.id,
      name: 'documents', blob_id: blob.id
    )

    CafStageDocument.create!(
      submission:    submission,
      document_uuid: attachment.uuid,
      document_name: blob.filename.to_s,
      internal_only: false
    )

    process_document_async(attachment)
  rescue StandardError => e
    Rails.logger.error("[CafSubmissionCreator] NDA agreement PDF generation failed for #{@caf.id}: #{e.message}")
  ensure
    File.delete(pdf_path) if pdf_path && File.exist?(pdf_path)
  end

  # Merges user-positioned fields from the agreement template into the
  # submission so the signing form renders them alongside the CAF fields.
  #
  # Because each agreement blob is re-attached at the submission level (new
  # ActiveStorage::Attachment record, different UUID), every area reference
  # must be remapped from the template attachment UUID to the corresponding
  # submission attachment UUID before merging.  When multiple documents are
  # uploaded, all template→submission UUID pairs are built into a single map
  # and applied in one pass over the fields array.
  #
  # NDA path: the submission IS the NDA template, so fields already reference
  # the correct attachment UUIDs.  No blobs were re-attached, so no remap is
  # needed — returning early leaves submission.template_fields nil and DocuSeal
  # renders the template's own fields directly.
  def merge_agreement_template_fields!(submission)
    return if @caf.agreement_type == 'nda'

    template = @caf.template
    return unless template && template.fields.present?

    # Build a complete remap: template attachment UUID → submission attachment UUID.
    # One entry per uploaded document.
    uuid_map = template.documents.attachments.each_with_object({}) do |src, map|
      sub_attach = ActiveStorage::Attachment.find_by(
        record_type: 'Submission', record_id: submission.id,
        name: 'documents', blob_id: src.blob_id
      )
      map[src.uuid] = sub_attach.uuid if sub_attach
    end

    return if uuid_map.empty?

    remapped = template.fields.map do |field|
      remapped_areas = (field['areas'] || []).map do |area|
        new_uuid = uuid_map[area['attachment_uuid']]
        new_uuid ? area.merge('attachment_uuid' => new_uuid) : area
      end
      field.merge('areas' => remapped_areas)
    end

    base_fields = submission.template&.fields || []
    submission.update!(template_fields: base_fields + remapped)
  end

  # Snapshots the submission's document schema so the signing form can resolve
  # all documents — both the template's signing page and the submission-level
  # attachments (CAF summary + agreement).
  #
  # Extends the base template schema with one entry per submission-level
  # document, then persists to submission.template_schema.
  def extend_submission_schema(submission)
    base_schema = submission.template&.schema || []
    existing_uuids = base_schema.to_set { |item| item['attachment_uuid'] }

    new_items = submission.documents_attachments.reject { |a| existing_uuids.include?(a.uuid) }.map do |att|
      { 'attachment_uuid' => att.uuid, 'name' => att.blob.filename.base }
    end

    return if new_items.empty?

    submission.update!(template_schema: base_schema + new_items)
  end

  def submission_name
    "CAF — #{@caf.caf_type_label} — #{@caf.contracting_party} — #{Date.current.strftime('%d %b %Y')}"
  end

  def caf_type_for_matrix
    case @caf.caf_type
    when 'nda'                      then 'nda'
    when 'short_form', 'long_form'  then 'contract'
    else                                 'other'
    end
  end

  # Returns the stable UUID of the 'Counterparty' slot in the IGSIGN CAF Template,
  # falling back to a fresh UUID if the template or slot is missing.
  def counterparty_uuid_from_template(submission)
    tpl_sub = (submission.template&.submitters || []).find { |s| s['name'] == 'Counterparty' }
    tpl_sub&.dig('uuid') || SecureRandom.uuid
  end

  def find_or_create_caf_template
    existing = @caf.account.templates.find_by(name: 'IGSIGN CAF Template')
    return existing if existing

    Template.create!(
      account: @caf.account,
      name: 'IGSIGN CAF Template',
      author: @user,
      fields: [],
      schema: [],
      submitters: [{ 'name' => 'Approver', 'uuid' => SecureRandom.uuid }]
    )
  end

  # TODO: Part C — AI-assisted CAF field extraction (SKIPPED — API key not available)
  #
  # When OPENROUTER_API_KEY (or ANTHROPIC_API_KEY) is available, implement:
  #
  #   class CafAiExtractor
  #     BASE_URL  = ENV.fetch('AI_BASE_URL', 'https://openrouter.ai/api/v1')
  #     MODEL     = ENV.fetch('AI_MODEL',    'anthropic/claude-3-haiku')
  #
  #     def initialize(caf)
  #       @caf = caf
  #     end
  #
  #     # Sends the uploaded contract text to the AI and returns a hash of
  #     # extracted CAF fields (agreement_purpose, agreement_value, agreement_term,
  #     # payment_terms, key_risks).  Returns {} on failure so the form stays
  #     # pre-populated with whatever the sender manually entered.
  #     def extract
  #       return {} unless api_key.present?
  #       prompt = build_prompt
  #       response = client.post('/chat/completions', body: { model: MODEL, messages: [...] })
  #       parse_response(response)
  #     rescue StandardError => e
  #       Rails.logger.warn("[CafAiExtractor] AI extraction failed: #{e.message}")
  #       {}
  #     end
  #
  #     private
  #     def api_key   = ENV['OPENROUTER_API_KEY'] || ENV['ANTHROPIC_API_KEY']
  #     def client    = Faraday.new(url: BASE_URL, headers: { 'Authorization' => "Bearer #{api_key}", 'Content-Type' => 'application/json' })
  #   end
  #
  # Call site: AgreementsController#review action, before rendering the review
  # form.  Auto-populate blank CAF fields with AI suggestions (shown as grey
  # placeholder text so the user can confirm/override before sending).
  #
  # Estimated effort: ~4h backend + 2h UI.  Blocked on: OPENROUTER_API_KEY in env.

  # DEPRECATED: NDA agreements no longer use a standing DocuSeal template.
  # The NDA document is generated dynamically by NdaAgreementGenerator.
  # This method is retained for reference only; it is no longer called.
  def find_nda_template!
    @caf.account.templates.find_by(name: 'IGSIGN NDA Template') ||
      raise(StandardError,
            'NDA Template has not been configured. ' \
            "Create it in the Templates editor (#{@caf.account.id}) first.")
  end

  # Builds the default stage chain based on the agreement type and entity.
  #
  # Stage layout:
  #   Position 0      — "Internal CAF Approval"  (parallel, all internal approvers)
  #   Position 1 … N-1 — "Group Signer Approval"  (ordered, one stage per group signer)
  #                       [absent for NDAs; 2 stages for Spot Connect: Siddeek → Sean]
  #   Position N       — "Counterparty Signing"   (parallel, populated at hand-off)
  #
  # strip_internal_on_complete is set on whichever stage is the last before Counterparty
  # so that the CAF summary PDF is marked as stripped at the correct transition point.
  def build_default_stages(submission)
    is_nda     = @caf.agreement_type == 'nda'
    group_subs = is_nda ? [] : submitters_by_chain_positions(submission, SEQUENTIAL_POSITIONS)

    # Stage 0: parallel internal approval
    # strip: true when this is also the last internal stage (NDA, or no group signers configured).
    stage0 = submission.caf_stages.create!(
      name:                       'Internal CAF Approval',
      position:                   0,
      routing:                    'parallel',
      strip_internal_on_complete: group_subs.empty?,
      status:                     'pending'
    )
    assign_stage_submitters(stage0, submitters_by_chain_positions(submission, INTERNAL_POSITIONS))

    # Stage 1 … N-1: sequential group signer(s) (skipped for NDAs)
    stage_pos = 1
    group_subs.each_with_index do |sub, i|
      is_last_group_signer = (i == group_subs.size - 1)
      stage = submission.caf_stages.create!(
        name:                       'Group Signer Approval',
        position:                   stage_pos,
        routing:                    'ordered',
        strip_internal_on_complete: is_last_group_signer,
        status:                     'pending'
      )
      CafStageSubmitter.create!(
        caf_stage: stage,
        submitter: sub,
        role:      sub.metadata&.dig('caf_role') || 'Group Signer',
        position:  0
      )
      stage_pos += 1
    end

    # Final stage: counterparty (always last; submitters populated at hand-off)
    submission.caf_stages.create!(
      name:                       'Counterparty Signing',
      position:                   stage_pos,
      routing:                    'parallel',
      strip_internal_on_complete: false,
      status:                     'pending'
    )
  end

  # Returns submission submitters whose chain_position falls in +positions+,
  # ordered by the prescribed position index so signing order is deterministic.
  def submitters_by_chain_positions(submission, positions)
    submission.submitters
              .select { |s| positions.include?(s.metadata&.dig('chain_position').to_s) }
              .sort_by { |s| positions.index(s.metadata&.dig('chain_position').to_s) || 999 }
  end

  # Assigns +subs+ to +stage+ as CafStageSubmitters, preserving supplied order.
  def assign_stage_submitters(stage, subs)
    subs.each_with_index do |sub, idx|
      CafStageSubmitter.create!(
        caf_stage: stage,
        submitter: sub,
        role:      sub.metadata&.dig('caf_role') || 'Approver',
        position:  idx
      )
    end
  end

  def process_document_async(attachment)
    Templates::ProcessDocument.call(attachment, attachment.download)
  rescue StandardError => e
    Rails.logger.warn("[CafSubmissionCreator] ProcessDocument skipped: #{e.message.truncate(120)}")
  end
end
