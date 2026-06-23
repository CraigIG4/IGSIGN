# frozen_string_literal: true

# Thin wrapper around the OpenRouter-compatible LLM API.
# Used by ContractParser (extraction) and ContractChatService (GCinmyPOCKET).
# Sprint 6 will add Azure OpenAI fallback here without changing callers.
module IgsignLlmClient
  BASE_URL      = -> { ENV.fetch('AI_BASE_URL', 'https://openrouter.ai/api/v1') }
  API_KEY       = -> { ENV.fetch('AI_API_KEY', nil) }
  DEFAULT_MODEL = 'meta-llama/llama-3.3-70b-instruct:free'

  def self.configured?
    API_KEY.call.present?
  end

  # Sends a messages array to the chat completions endpoint.
  # Returns the content string on success, raises on HTTP/network error.
  def self.chat(messages, model: nil, temperature: 0.2, json_mode: false)
    raise 'AI_API_KEY not configured' unless configured?

    conn = Faraday.new(url: BASE_URL.call) do |f|
      f.request :json
      f.response :json
      f.headers['Authorization'] = "Bearer #{API_KEY.call}"
      f.headers['HTTP-Referer']  = 'https://igsign.ignitiongroup.co.za'
      f.headers['X-Title']       = 'IGSIGN'
    end

    payload = {
      model: model || ENV.fetch('AI_MODEL', DEFAULT_MODEL),
      messages:,
      temperature:
    }
    payload[:response_format] = { type: 'json_object' } if json_mode

    resp = conn.post('chat/completions', payload)

    raise "HTTP #{resp.status}: #{resp.body}" unless resp.success?

    content = resp.body.dig('choices', 0, 'message', 'content')
    raise 'Empty LLM response' if content.blank?

    content
  end
end
