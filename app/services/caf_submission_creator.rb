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
    attach_contract_document(submission)
    merge_agreement_template_fields!(submission)
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
    # NDA agreements use the standing NDA Template (pre-built document + fields).
    # All other types use the generic CAF Template which provides the signing-page
    # submitter slots; the actual document is attached separately by
    # attach_contract_document.
    template = @caf.agreement_type == 'nda' ? find_nda_template! : find_or_create_caf_template

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
        metadata: { 'caf_role' => sig['role'], 'caf_position' => idx }
      )
    end
  end

  def attach_stages(submission)
    matrix = CafApprovalMatrix.for(@caf.account, caf_type_for_matrix)
    if matrix
      matrix.build_stages_for(submission).each(&:save!)
    else
      build_default_stages(submission)
    end
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
  #
  # Upload path: blobs from @caf.template are re-attached to the submission as
  # new ActiveStorage::Attachment records (new UUIDs).  CafStageDocument entries
  # reference those new submission-level UUIDs.
  #
  # NDA path: the NDA document is already embedded in the NDA Template's schema
  # which the submission inherits.  Re-attaching the blob would duplicate the
  # document in the signing form.  Instead, CafStageDocument entries are created
  # directly from the template schema using the template-level attachment UUIDs.
  def attach_contract_document(submission)
    template = @caf.template
    return unless template

    if @caf.agreement_type == 'nda'
      (template.schema || []).each do |item|
        CafStageDocument.create!(
          submission:    submission,
          document_uuid: item['attachment_uuid'],
          document_name: item['name'].to_s,
          internal_only: false
        )
      end
    else
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
    existing_uuids = base_schema.map { |item| item['attachment_uuid'] }.to_set

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

  # Looks up the standing NDA Template.  Raises with an actionable message if
  # it has not been created yet so the error surfaces cleanly at Send time.
  def find_nda_template!
    @caf.account.templates.find_by(name: 'IGSIGN NDA Template') ||
      raise(StandardError,
            'NDA Template has not been configured. ' \
            "Create it in the Templates editor (#{@caf.account.id}) first.")
  end

  def build_default_stages(submission)
    stage1 = create_internal_stage(submission)
    assign_submitters_to_stage(submission, stage1)
    create_counterparty_stage(submission)
  end

  def create_internal_stage(submission)
    submission.caf_stages.create!(
      name: 'Internal CAF Approval',
      position: 0,
      routing: 'ordered',
      strip_internal_on_complete: true,
      status: 'active',
      activated_at: Time.current
    )
  end

  def assign_submitters_to_stage(submission, stage)
    submission.submitters.order(created_at: :asc).each_with_index do |submitter, idx|
      CafStageSubmitter.create!(
        caf_stage: stage,
        submitter: submitter,
        role: submitter.metadata&.dig('caf_role') || 'Approver',
        position: idx
      )
    end
  end

  def create_counterparty_stage(submission)
    submission.caf_stages.create!(
      name: 'Counterparty Signing',
      position: 1,
      routing: 'parallel',
      strip_internal_on_complete: false,
      status: 'pending'
    )
  end

  def process_document_async(attachment)
    Templates::ProcessDocument.call(attachment, attachment.download)
  rescue StandardError => e
    Rails.logger.warn("[CafSubmissionCreator] ProcessDocument skipped: #{e.message.truncate(120)}")
  end
end
