# frozen_string_literal: true

# IGSIGN — OpenRouter-based contract metadata extraction.
#
# Two-pass extraction driven by CafFieldSchema.
# Handles models that don't support response_format/json_object by falling back
# to plain-text mode and extracting JSON from the response.
class ContractParser
  MAX_CHARS = 24_000

  class << self
    def extract(contract_text)
      return { 'error' => 'AI_API_KEY not configured' } unless IgsignLlmClient.configured?

      truncated = contract_text.to_s.slice(0, MAX_CHARS)

      contract_type = extract_contract_type(truncated)
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
        Extract only the contract_type from this agreement.
        #{type_field[:prompt_guide]}
        Return ONLY valid JSON with a single key "contract_type". No markdown, no preamble.
      PROMPT

      raw = llm_call([{ role: 'system', content: prompt }, { role: 'user', content: text }])
      parsed = safe_parse_json(raw)
      parsed['contract_type'].to_s
    rescue StandardError
      ''
    end

    def extract_fields(text, fields)
      system_prompt = build_prompt(fields)
      raw = llm_call([{ role: 'system', content: system_prompt }, { role: 'user', content: text }])
      safe_parse_json(raw)
    rescue StandardError => e
      Rails.logger.error("[IGSIGN] ContractParser extract_fields error: #{e.message}")
      { 'error' => e.message }
    end

    # Try json_mode first; if the model returns empty, fall back to plain text
    # and extract JSON from the response. Handles models like gpt-oss-120b that
    # do not support response_format: json_object.
    def llm_call(messages)
      raw = IgsignLlmClient.chat(messages, temperature: 0.1, json_mode: true)
      return raw if raw.present?

      # Fallback: plain call without json_mode
      Rails.logger.info('[IGSIGN] ContractParser: json_mode returned empty, retrying without')
      IgsignLlmClient.chat(messages, temperature: 0.1, json_mode: false)
    rescue StandardError
      # json_mode may have raised — try without it
      IgsignLlmClient.chat(messages, temperature: 0.1, json_mode: false)
    end

    # Extract JSON from a response that may be wrapped in markdown code fences.
    def safe_parse_json(raw)
      return {} if raw.blank?

      # Strip markdown code fences if present: ```json ... ```
      cleaned = raw.strip
                   .gsub(/\A```(?:json)?\s*/i, '')
                   .gsub(/\s*```\z/, '')
                   .strip

      # Find the first { ... } block in case the model added explanation around the JSON
      if (match = cleaned.match(/\{.*\}/m))
        cleaned = match[0]
      end

      JSON.parse(cleaned)
    rescue JSON::ParserError => e
      Rails.logger.error("[IGSIGN] ContractParser JSON parse error: #{e.message.truncate(120)}")
      { 'error' => "JSON parse error: #{e.message}" }
    end

    def build_prompt(fields)
      field_instructions = fields.map do |f|
        "#{f[:key]}: #{f[:prompt_guide].strip}#{type_hint_for(f)}"
      end.join("\n\n")

      <<~PROMPT
        You are a legal contract analyst for Ignition Group, a South African technology conglomerate.
        Extract structured metadata from the contract text provided.

        CRITICAL RULE: Summarise — never copy clause text verbatim. Write values in plain English
        as if briefing an executive who has not read the contract.

        #{field_instructions}

        clause_refs: For every field you populate (not null, not "Not Included"), include the
        clause or section reference from the contract where that information was found.
        Return as a JSON object mapping field_key to clause reference string.
        Example: {"liability_aggregate_cap": "Clause 14.3", "governing_law": "Section 22.1(a)"}
        Use null if no clause reference is identifiable for a field.

        Return ONLY valid JSON with all the field keys above PLUS a "clause_refs" key.
        No markdown code fences, no preamble, no explanation — only the JSON object.
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
