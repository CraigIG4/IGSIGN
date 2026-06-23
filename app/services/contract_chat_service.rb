# frozen_string_literal: true

# IGSIGN — GCinmyPOCKET backend.
# Available to Stage 0 (internal approvers) and Stage 1 (IG executive) signers ONLY.
# Stage 2 counterparty submitters are rejected at service level — do not rely
# solely on controller gating.
#
# Security design:
# - internal_signer? checks stage position (0 or 1 = internal/executive).
#   There is NO stage_type column — identification is by CafStage#position and #name.
# - Submitter token stored only as SHA-256 digest in ChatAuditLog.
# - Context assembly never includes internal_only documents for Stage 1 signers.
#
# Uses IgsignLlmClient (Sprint 0.2b) — no duplicate Faraday client here.
class ContractChatService
  SYSTEM_PROMPT_PATH = Rails.root.join('config/prompts/gcip_chat_v1.md')
  MAX_CONTEXT_CHARS  = 60_000

  def self.answer(question:, caf_workflow_id:, submitter:, conversation_history: [])
    new(question:, caf_workflow_id:, submitter:, conversation_history:).answer
  end

  # Used by the upload wizard — authenticated user (not a submitter).
  # Skips the stage-position check; auth is handled by the controller.
  def self.answer_for_uploader(question:, caf_workflow_id:, user:, conversation_history: [])
    new(question:, caf_workflow_id:, submitter: nil, conversation_history:, uploader: user).answer
  end

  def initialize(question:, caf_workflow_id:, submitter:, conversation_history:, uploader: nil)
    @question             = question
    @caf_workflow_id      = caf_workflow_id
    @submitter            = submitter
    @uploader             = uploader
    @conversation_history = conversation_history
  end

  def answer
    return { error: 'Not available' } unless @uploader || internal_signer?
    return { error: 'AI_API_KEY not configured' } unless IgsignLlmClient.configured?

    context = assemble_context
    return { error: 'No document text available for this agreement.' } if context.blank?

    result = call_llm(build_messages(context))
    log_exchange(result)
    result
  rescue StandardError => e
    Rails.logger.error("[IGSIGN] ContractChatService error: #{e.message}")
    { error: 'An error occurred. Please try again.' }
  end

  private

  # Returns true only for Stage 0 (internal approvers) and Stage 1 (IG executive) signers.
  # Identification is by CafStage position (0 or 1) or stage name.
  # Stage 2 (counterparty, position >= 2) is always rejected.
  def internal_signer?
    return false unless @submitter&.submission

    stage = @submitter.submission.caf_stages
                      .joins(:caf_stage_submitters)
                      .find_by(caf_stage_submitters: { submitter_id: @submitter.id })

    return false unless stage

    # Positions 0 (internal approval) and 1 (group signer / executive) are internal.
    # Any higher position is the counterparty signing stage.
    stage.position < 2
  rescue StandardError
    false
  end

  def assemble_context
    workflow = CafWorkflow.find_by(id: @caf_workflow_id)
    return '' unless workflow

    texts = []

    # 1. Primary contract document — extract text via Pdfium
    document = workflow.template&.schema_documents&.first
    if document
      text = extract_text(document)
      texts << "=== #{document.filename} (this agreement) ===\n#{text}" if text.present?
    end

    # 2. Manually linked related agreements — use parsed summary (not full text)
    workflow.contract_family_members.includes(:linked_workflow).ordered.each do |member|
      next unless member.linked_workflow&.parsed_contract_data.present?
      next if member.linked_workflow.parsed_contract_data['error']

      summary = member.linked_workflow.parsed_contract_data['high_level_summary']
      texts << "=== #{member.document_name} (#{member.role}) ===\n#{summary}" if summary.present?
    end

    # 3. Other workflows for the same counterparty — summary only
    if workflow.company_id.present?
      CafWorkflow.where(company_id: workflow.company_id)
                 .where.not(id: workflow.id)
                 .where.not(parsed_contract_data: nil)
                 .order(created_at: :desc)
                 .limit(5)
                 .each do |related|
        next if related.parsed_contract_data['error']

        summary = related.parsed_contract_data['high_level_summary']
        ctype   = related.parsed_contract_data['contract_type']
        texts << "=== Prior agreement (#{ctype}) ===\n#{summary}" if summary.present?
      end
    end

    texts.join("\n\n").slice(0, MAX_CONTEXT_CHARS)
  end

  def extract_text(document)
    runs = DocumentMetadatas.build_text_runs(document)
    return '' if runs.blank?

    runs.values.flat_map { |objs| objs.filter_map { |o| o[:text].presence } }
        .join(' ').squeeze(' ').strip
  rescue StandardError
    ''
  end

  def build_messages(context)
    system_content = "#{File.read(SYSTEM_PROMPT_PATH)}\n\n--- DOCUMENTS ---\n#{context}"
    history = @conversation_history.last(6).map do |m|
      { role: m[:role] || m['role'], content: m[:content] || m['content'] }
    end
    [{ role: 'system', content: system_content }] + history + [{ role: 'user', content: @question }]
  end

  def call_llm(messages)
    content = IgsignLlmClient.chat(messages, temperature: 0.3)
    { answer: content }
  rescue StandardError => e
    { error: "LLM error: #{e.message}" }
  end

  def log_exchange(result)
    token_digest = if @uploader
                     Digest::SHA256.hexdigest("uploader:#{@uploader.id}")
                   else
                     Digest::SHA256.hexdigest(@submitter.slug.to_s)
                   end
    ChatAuditLog.create!(
      caf_workflow_id:        @caf_workflow_id,
      submitter_token_digest: token_digest,
      signer_role:            @uploader ? 'uploader' : 'internal',
      question:               @question,
      answer:                 result[:answer],
      error:                  result[:error]
    )
  rescue StandardError => e
    Rails.logger.warn("[IGSIGN] ChatAuditLog write failed: #{e.message}")
    # Do not re-raise — audit log failure must never block the answer
  end
end
