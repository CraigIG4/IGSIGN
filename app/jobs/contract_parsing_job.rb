# frozen_string_literal: true

# IGSIGN — Background job to extract contract metadata via OpenRouter.
#
# Enqueued after a document is uploaded to an agreement (AgreementsController#process_upload).
# Extracts text from the uploaded PDF using Pdfium, calls ContractParser (two-pass extraction
# driven by CafFieldSchema), and saves the result to both:
#   - caf_workflow.parsed_contract_data (jsonb) — full extraction result
#   - individual native columns (driven by CafFieldSchema.caf_column_fields) — for dashboard queries
#
# Failure is intentionally silent — an error key is saved to parsed_contract_data
# so the review page can show a degraded state, but the upload/signing flow is never blocked.
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

    ActiveRecord::Associations::Preloader.new(records: [document], associations: [:blob]).call

    text = extract_text(document)
    if text.blank?
      Rails.logger.warn("[IGSIGN] ContractParsingJob: text extraction empty for workflow #{caf_workflow_id}")
      agreement.update_columns(parsed_contract_data: { 'error' => 'Text extraction returned no content' })
      return
    end

    result = ContractParser.extract(text)
    agreement.update_columns(parsed_contract_data: result)

    unless result['error']
      write_native_columns(agreement, result)
      autofill_counterparty(agreement, result)
    end

    Rails.logger.info("[IGSIGN] ContractParsingJob: complete for #{caf_workflow_id}, keys=#{result.keys.join(',')}")
  rescue StandardError => e
    Rails.logger.error("[IGSIGN] ContractParsingJob error for #{caf_workflow_id}: #{e.message}")
  end

  private

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

  # Fills counterparty name + email only when the handler has not entered them yet.
  # Never overwrites a manually entered value — this is a convenience pre-fill only.
  def autofill_counterparty(agreement, result)
    updates = {}
    updates[:contracting_party] = result['counterparty_name'].strip if
      result['counterparty_name'].present? && agreement.contracting_party.blank?
    updates[:counterparty_email] = result['counterparty_contact_email'].strip if
      result['counterparty_contact_email'].present? && agreement.counterparty_email.blank?
    agreement.update_columns(updates) if updates.any?
  rescue StandardError => e
    Rails.logger.warn("[IGSIGN] ContractParsingJob autofill_counterparty error: #{e.message}")
  end

  # Writes AI-extracted values to native columns for dashboard queries.
  # Only writes fields where the result has a non-nil value AND the field has a caf_column.
  # Preserves any field with existing 'manual' provenance — AI re-runs must not overwrite manual entries.
  def write_native_columns(agreement, result)
    existing_provenance = agreement.parsed_data_provenance.presence || {}
    native_updates = {}
    provenance_updates = {}

    CafFieldSchema.caf_column_fields.each do |field|
      value = result[field[:key].to_s]
      next if value.nil?

      # Preserve manual entries — never overwrite what legal ops has entered by hand
      next if existing_provenance[field[:key].to_s] == 'manual'

      # Arrays (e.g. material_risks) are joined to a string for text columns
      col_value = field[:type] == :array ? Array(value).join('; ') : value

      native_updates[field[:caf_column]] = col_value
      provenance_updates[field[:key].to_s] = 'ai'
    end

    return if native_updates.empty?

    native_updates[:parsed_data_provenance] = existing_provenance.merge(provenance_updates)
    agreement.update_columns(native_updates)
  end
end
