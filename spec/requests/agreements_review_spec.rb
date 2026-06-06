# frozen_string_literal: true

require 'rails_helper'

# Sprint 1: verify the review page pre-fill behaviour under all parsed_contract_data states.
RSpec.describe 'Agreements review pre-fill', type: :request do
  let(:account) { create(:account) }
  let(:user)    { create(:user, account: account, role: User::ADMIN_ROLE, confirmed_at: Time.current) }
  let(:workflow) { create(:caf_workflow, account: account, created_by_user: user) }

  before do
    load Rails.root.join('db/seeds/igsign_registry.rb')
    sign_in user
  end

  def get_review
    get review_agreement_path(workflow)
  end

  describe 'GET /agreements/:id/review' do
    context 'when parsed_contract_data is nil (extraction not yet run)' do
      before { workflow.update_columns(parsed_contract_data: nil, parsed_data_provenance: {}) }

      it 'renders successfully' do
        get_review
        expect(response).to have_http_status(:ok)
      end

      it 'shows the pending extraction banner' do
        get_review
        expect(response.body).to include('AI extraction is pending')
      end

      it 'does not show the pre-filled banner' do
        get_review
        expect(response.body).not_to include('Fields pre-filled from contract')
      end
    end

    context 'when parsed_contract_data contains an error' do
      before do
        workflow.update_columns(
          parsed_contract_data: { 'error' => 'HTTP 429: rate limited' },
          parsed_data_provenance: {}
        )
      end

      it 'renders successfully' do
        get_review
        expect(response).to have_http_status(:ok)
      end

      it 'shows the extraction failed banner' do
        get_review
        expect(response.body).to include('Automatic extraction failed')
      end

      it 'does not show the smart summary card' do
        get_review
        expect(response.body).not_to include('Smart Summary')
      end
    end

    context 'when parsed_contract_data has partial AI data' do
      before do
        workflow.update_columns(
          high_level_summary:    'This is a test MSA.',
          agreement_value:       'ZAR 500,000 per annum',
          governing_law:         'Republic of South Africa',
          parsed_contract_data:  { 'contract_type' => 'MSA', 'high_level_summary' => 'This is a test MSA.' },
          parsed_data_provenance: { 'contract_type' => 'ai', 'high_level_summary' => 'ai', 'governing_law' => 'ai' }
        )
      end

      it 'shows the pre-filled banner' do
        get_review
        expect(response.body).to include('Fields pre-filled from contract')
      end

      it 'shows the smart summary card' do
        get_review
        expect(response.body).to include('Smart Summary')
      end

      it 'shows the high level summary text' do
        get_review
        expect(response.body).to include('This is a test MSA.')
      end

      it 'shows a link to the contract_data review page' do
        get_review
        expect(response.body).to include(contract_data_legal_ops_workflow_path(workflow))
      end
    end

    context 'when parsed_contract_data includes amends_or_relates_to' do
      before do
        workflow.update_columns(
          parsed_contract_data:   { 'amends_or_relates_to' => ['Master Services Agreement dated 1 Jan 2024'] },
          parsed_data_provenance: { 'amends_or_relates_to' => 'ai' }
        )
      end

      it 'shows the amends suggestion banner' do
        get_review
        expect(response.body).to include('This document references related agreements')
        expect(response.body).to include('Master Services Agreement dated 1 Jan 2024')
      end
    end

    context 'when liability_cap is Not Included' do
      before do
        workflow.update_columns(
          liability_cap:          'Not Included',
          parsed_contract_data:   { 'liability_aggregate_cap' => 'Not Included' },
          parsed_data_provenance: { 'liability_aggregate_cap' => 'ai' }
        )
      end

      it 'shows the liability risk flag' do
        get_review
        expect(response.body).to include('No aggregate liability cap')
      end
    end
  end
end
