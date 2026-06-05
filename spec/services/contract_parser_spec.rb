# frozen_string_literal: true

require 'rails_helper'

RSpec.describe ContractParser, type: :model do
  let(:sample_text) { 'This is a Master Services Agreement between Ignition Group and Acme Corp.' }

  describe '.extract' do
    context 'when AI_API_KEY is not configured' do
      before { allow(IgsignLlmClient).to receive(:configured?).and_return(false) }

      it 'returns an error hash without calling the LLM' do
        expect(IgsignLlmClient).not_to receive(:chat)
        result = described_class.extract(sample_text)
        expect(result).to eq({ 'error' => 'AI_API_KEY not configured' })
      end
    end

    context 'when AI is configured' do
      before { allow(IgsignLlmClient).to receive(:configured?).and_return(true) }

      it 'performs a first-pass type extraction then a second-pass full extraction' do
        expect(IgsignLlmClient).to receive(:chat).once.ordered
          .with(anything, hash_including(json_mode: true, temperature: 0.1))
          .and_return('{"contract_type":"MSA"}')

        expect(IgsignLlmClient).to receive(:chat).once.ordered
          .with(anything, hash_including(json_mode: true, temperature: 0.1))
          .and_return('{"contract_type":"MSA","high_level_summary":"An MSA"}')

        result = described_class.extract(sample_text)
        expect(result).to include('contract_type' => 'MSA', 'high_level_summary' => 'An MSA')
      end

      it 'excludes change_in_addendum from second pass when type is MSA' do
        allow(IgsignLlmClient).to receive(:chat).once.ordered.and_return('{"contract_type":"MSA"}')

        allow(IgsignLlmClient).to receive(:chat).once.ordered do |messages, **|
          system_msg = messages.first[:content]
          expect(system_msg).not_to include('change_in_addendum')
          '{"contract_type":"MSA"}'
        end

        described_class.extract(sample_text)
      end

      it 'includes change_in_addendum in second pass when type is Addendum' do
        allow(IgsignLlmClient).to receive(:chat).once.ordered.and_return('{"contract_type":"Addendum"}')

        allow(IgsignLlmClient).to receive(:chat).once.ordered do |messages, **|
          system_msg = messages.first[:content]
          expect(system_msg).to include('change_in_addendum')
          '{"contract_type":"Addendum","change_in_addendum":"Extends term by 12 months"}'
        end

        result = described_class.extract(sample_text)
        expect(result['change_in_addendum']).to eq('Extends term by 12 months')
      end

      it 'returns error hash on JSON parse failure' do
        allow(IgsignLlmClient).to receive(:chat).and_return('{"contract_type":"MSA"}', 'NOT JSON}')
        result = described_class.extract(sample_text)
        expect(result['error']).to match(/JSON parse error/i)
      end

      it 'returns error hash on LLM network failure' do
        allow(IgsignLlmClient).to receive(:chat).and_raise(StandardError, 'Connection refused')
        result = described_class.extract(sample_text)
        expect(result['error']).to eq('Connection refused')
      end

      it 'truncates contract text to MAX_CHARS' do
        long_text = 'x' * 30_000
        allow(IgsignLlmClient).to receive(:chat) do |messages, **|
          user_content = messages.last[:content]
          expect(user_content.length).to be <= ContractParser::MAX_CHARS
          '{"contract_type":"MSA"}'
        end
        described_class.extract(long_text)
      end
    end
  end
end
