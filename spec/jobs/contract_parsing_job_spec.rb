# frozen_string_literal: true

require 'rails_helper'

RSpec.describe ContractParsingJob, type: :job do
  let(:account)  { create(:account) }
  let(:user)     { create(:user, account: account) }
  let(:workflow) { create(:caf_workflow, account: account, created_by_user: user) }

  describe '#perform' do
    context 'when the workflow does not exist' do
      it 'logs a warning and returns without error' do
        expect(Rails.logger).to receive(:warn).with(/not found/i)
        expect { described_class.new.perform(0) }.not_to raise_error
      end
    end

    context 'when the workflow has no template' do
      it 'logs and returns without error' do
        expect(Rails.logger).to receive(:info).with(/no document/i)
        expect { described_class.new.perform(workflow.id) }.not_to raise_error
      end
    end

    context 'when text extraction succeeds and AI returns data' do
      let(:template)  { create(:template, account: account) }
      let(:parsed_result) do
        {
          'contract_type' => 'MSA',
          'high_level_summary' => 'A test MSA',
          'governing_law' => 'Republic of South Africa',
          'expiry_date' => '2027-01-01',
          'material_risks' => ['Risk one', 'Risk two']
        }
      end

      before do
        workflow.update!(template: template)
        allow_any_instance_of(described_class).to receive(:extract_text).and_return('Contract text here')
        allow(ContractParser).to receive(:extract).and_return(parsed_result)
      end

      it 'saves parsed_contract_data to the workflow' do
        described_class.new.perform(workflow.id)
        expect(workflow.reload.parsed_contract_data).to eq(parsed_result)
      end

      it 'writes native columns from CafFieldSchema mapping' do
        described_class.new.perform(workflow.id)
        wf = workflow.reload
        expect(wf.agreement_type).to eq('MSA')
        expect(wf.high_level_summary).to eq('A test MSA')
        expect(wf.governing_law).to eq('Republic of South Africa')
      end

      it 'sets provenance to ai for AI-extracted fields' do
        described_class.new.perform(workflow.id)
        prov = workflow.reload.parsed_data_provenance
        expect(prov['contract_type']).to eq('ai')
        expect(prov['governing_law']).to eq('ai')
      end

      it 'preserves manual provenance fields on re-run' do
        workflow.update_columns(
          parsed_data_provenance: { 'governing_law' => 'manual' },
          governing_law: 'England and Wales'
        )
        described_class.new.perform(workflow.id)
        wf = workflow.reload
        expect(wf.governing_law).to eq('England and Wales')
        expect(wf.parsed_data_provenance['governing_law']).to eq('manual')
      end

      it 'joins array fields as semicolon-separated string for native columns' do
        described_class.new.perform(workflow.id)
        expect(workflow.reload.key_risks).to eq('Risk one; Risk two')
      end
    end

    context 'when AI returns an error' do
      let(:template) { create(:template, account: account) }

      before do
        workflow.update!(template: template)
        allow_any_instance_of(described_class).to receive(:extract_text).and_return('text')
        allow(ContractParser).to receive(:extract).and_return({ 'error' => 'AI failed' })
      end

      it 'saves the error to parsed_contract_data' do
        described_class.new.perform(workflow.id)
        expect(workflow.reload.parsed_contract_data).to eq({ 'error' => 'AI failed' })
      end

      it 'does not write to native columns' do
        described_class.new.perform(workflow.id)
        expect(workflow.reload.governing_law).to be_nil
      end
    end
  end
end
