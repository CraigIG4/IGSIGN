# frozen_string_literal: true

# IGSIGN — OpenRouter-based contract metadata extraction.
#
# Generates its extraction prompt dynamically from CafFieldSchema — adding a field
# to the schema automatically adds it to the prompt. Uses two-pass extraction:
# pass 1 identifies contract_type; pass 2 runs the full extraction with only the
# fields active for that contract type (prevents hallucination of conditional fields).
#
# PRIVACY NOTE: Contract text is sent to OpenRouter, which routes to a
# third-party hosted model (e.g. Meta Llama). Acceptable for POC.
# For production, switch to Azure OpenAI (Sprint 6). See CLAUDE.md.
class ContractParser
  # 24 000 chars ≈ 6 000 tokens — well within Llama-3.3-70b's 128k window.
  MAX_CHARS = 24_000

  class << self
    # Extracts structured metadata from contract_text.
    # Returns a Hash on success. On any failure returns { 'error' => <message> }.
    # Never raises — ContractParsingJob logs errors and continues.
    def extract(contract_text)
      return { 'error' => 'AI_API_KEY not configured' } unless IgsignLlmClient.configured?

      truncated = contract_text.to_s.slice(0, MAX_CHARS)

      # Pass 1 — identify contract_type only (fast, minimal prompt)
      contract_type = extract_contract_type(truncated)

      # Pass 2 — full extraction with fields active for this contract type
      active_fields = CafFieldSchema.active_fields_for_type(contract_type)
      extract_fields(truncated, active_fields)
    rescue StandardError => e
      Rails.logger.error("[IGSIGN] ContractParser failed: #{e.message}")
      { 'error' => e.message }
    end

    private

    def extract_contract_type(text)
      type_field = CafFieldSchema.field(:contract_type)
      prompt = <<~PROMPT
        Extract only the contract_type from this agreement. Return a JSON object with a single key "contract_type".
        #{type_field[:prompt_guide]}
        Return ONLY valid JSON. No markdown, no preamble.
      PROMPT

      raw = IgsignLlmClient.chat(
        [{ role: 'system', content: prompt }, { role: 'user', content: text }],
        temperature: 0.1,
        json_mode: true
      )
      JSON.parse(raw)['contract_type'].to_s
    rescue StandardError
      ''
    end

    def extract_fields(text, fields)
      system_prompt = build_prompt(fields)
      raw = IgsignLlmClient.chat(
        [{ role: 'system', content: system_prompt }, { role: 'user', content: text }],
        temperature: 0.1,
        json_mode: true
      )
      JSON.parse(raw)
    rescue JSON::ParserError => e
      Rails.logger.error("[IGSIGN] ContractParser JSON parse error: #{e.message}")
      { 'error' => "JSON parse error: #{e.message}" }
    rescue StandardError => e
      Rails.logger.error("[IGSIGN] ContractParser network error: #{e.message}")
      { 'error' => e.message }
    end

    def build_prompt(fields)
      field_instructions = fields.map do |f|
        type_hint = type_hint_for(f)
        "#{f[:key]}: #{f[:prompt_guide].strip}#{type_hint}"
      end.join("\n\n")

      <<~PROMPT
        You are a legal contract analyst for Ignition Group, a South African technology conglomerate.
        Extract structured metadata from the contract text provided.

        For each field below, follow the specific instruction exactly.
        CRITICAL RULE: Summarise — never copy clause text verbatim. Write values in plain English
        as if briefing an executive who has not read the contract.

        #{field_instructions}

        Return ONLY valid JSON with keys matching the field names above.
        No markdown, no preamble, no explanation — only the JSON object.
      PROMPT
    end

    def type_hint_for(field)
      case field[:type]
      when :date    then ' (format: YYYY-MM-DD or null)'
      when :boolean then ' (true/false/null)'
      when :integer then ' (integer or null)'
      when :array   then ' (JSON array of strings)'
      when :enum    then " (one of: #{field[:options].join(', ')})"
      else               ''
      end
    end
  end
end
