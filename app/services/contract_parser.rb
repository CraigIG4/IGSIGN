# frozen_string_literal: true

# IGSIGN — OpenRouter-based contract metadata extraction.
#
# Uses Faraday against the OpenAI-compatible endpoint at AI_BASE_URL.
# Model is set by AI_MODEL (default: meta-llama/llama-3.3-70b-instruct:free).
#
# PRIVACY NOTE: Contract text is sent to OpenRouter, which routes to a
# third-party hosted model (e.g. Meta Llama). This is acceptable for the
# IGSIGN POC phase. For production with live client contracts, switch to a
# self-hosted model or a provider with a zero-data-retention agreement.
# See CLAUDE.md for env var documentation.
class ContractParser
  SYSTEM_PROMPT_PATH = Rails.root.join('config/prompts/extract_contract_v1.md')
  # 24 000 chars ≈ 6 000 tokens — well within Llama-3.3-70b's 128k window.
  # Truncating avoids accidental overruns on large contracts.
  MAX_CHARS = 24_000

  class << self
    # Extracts structured metadata from contract_text.
    # Returns a Hash on success. On any failure returns { 'error' => <message> }.
    # Never raises — callers (ContractParsingJob) log errors and continue.
    def extract(contract_text)
      return { 'error' => 'AI_API_KEY not configured' } if ENV['AI_API_KEY'].blank?
      return { 'error' => 'AI_BASE_URL not configured' }  if ENV['AI_BASE_URL'].blank?

      truncated = contract_text.to_s.slice(0, MAX_CHARS)

      client = build_client
      response = client.post('chat/completions', {
        model:           ENV.fetch('AI_MODEL', 'meta-llama/llama-3.3-70b-instruct:free'),
        messages:        [
          { role: 'system', content: system_prompt },
          { role: 'user',   content: truncated }
        ],
        response_format: { type: 'json_object' },
        temperature:     0.1
      })

      raise "OpenRouter returned HTTP #{response.status}" unless response.success?

      content = response.body.dig('choices', 0, 'message', 'content')
      raise 'Empty response from model' if content.blank?

      JSON.parse(content)
    rescue JSON::ParserError => e
      Rails.logger.error("[IGSIGN] ContractParser JSON parse error: #{e.message}")
      { 'error' => "JSON parse error: #{e.message}" }
    rescue Faraday::Error => e
      Rails.logger.error("[IGSIGN] ContractParser network error: #{e.message}")
      { 'error' => "Network error: #{e.message}" }
    rescue StandardError => e
      Rails.logger.error("[IGSIGN] ContractParser failed: #{e.message}")
      { 'error' => e.message }
    end

    private

    def build_client
      Faraday.new(url: ENV['AI_BASE_URL']) do |f|
        f.request  :json
        f.response :json
        f.adapter  Faraday.default_adapter
        f.headers['Authorization'] = "Bearer #{ENV['AI_API_KEY']}"
        f.headers['HTTP-Referer']  = 'https://igsign.ignitiongroup.co.za'
        f.headers['X-Title']       = 'IGSIGN Contract Parser'
      end
    end

    def system_prompt
      @system_prompt ||= File.read(SYSTEM_PROMPT_PATH)
    end
  end
end
