# frozen_string_literal: true

# IGSIGN — Background job to extract contract metadata via OpenRouter.
#
# Enqueued after a document is uploaded to an agreement. Extracts text from
# the uploaded PDF using the existing Pdfium library, calls ContractParser,
# and saves the result to caf_workflow.parsed_contract_data (jsonb).
#
# Failure is intentionally silent — an error key is saved to parsed_contract_data
# so the review page can show a degraded state, but the upload/signing flow
# is never blocked.
class ContractParsingJob < ApplicationJob
  queue_as :default

  def perform(caf_workflow_id)
    agreement = CafWorkflow.find_by(id: caf_workflow_id)
    unless agreement
      Rails.logger.warn("[IGSIGN] ContractParsingJob: CafWorkflow #{caf_workflow_id} not found")
      return
    end

    document = agreement.template&.schema_documents&.first
    unless document
      Rails.logger.info("[IGSIGN] ContractParsingJob: no document for workflow #{caf_workflow_id}")
      return
    end

    # Preload blob so metadata and download work without N+1
    ActiveRecord::Associations::Preloader.new(records: [document], associations: [:blob]).call

    text = extract_text(document)
    if text.blank?
      Rails.logger.warn("[IGSIGN] ContractParsingJob: text extraction empty for workflow #{caf_workflow_id}")
      agreement.update_columns(parsed_contract_data: { 'error' => 'Text extraction returned no content' })
      return
    end

    result = ContractParser.extract(text)
    agreement.update_columns(parsed_contract_data: result)

    Rails.logger.info("[IGSIGN] ContractParsingJob: complete for #{caf_workflow_id}, keys=#{result.keys.join(',')}")
  rescue StandardError => e
    Rails.logger.error("[IGSIGN] ContractParsingJob error for #{caf_workflow_id}: #{e.message}")
    # Do not re-raise — parsing failure must never block the signing workflow
  end

  private

  # Extracts all text from a PDF attachment using the Pdfium library.
  # Returns a plain string with all text objects joined by spaces.
  # Falls back to empty string on error (scanned/image PDFs, corrupt files, etc.)
  def extract_text(document)
    text_runs = DocumentMetadatas.build_text_runs(document)
    return '' if text_runs.blank?

    text_runs.values.flat_map do |page_objects|
      page_objects.filter_map { |obj| obj[:text].presence || obj['text'].presence }
    end.join(' ').squeeze(' ').strip
  rescue StandardError => e
    Rails.logger.warn("[IGSIGN] ContractParsingJob text extraction error: #{e.message}")
    ''
  end
end
