# frozen_string_literal: true

require 'rails_helper'

RSpec.describe 'Agreements index — staff walkthrough', type: :request do
  let(:account) { create(:account) }

  describe 'tour rendering conditions' do
    context 'when the user has never completed the walkthrough' do
      let(:user) { create(:user, account: account, walkthrough_completed_at: nil) }

      before { sign_in user }

      it 'includes the tour markup in the page' do
        get agreements_path
        expect(response).to have_http_status(:ok)
        expect(response.body).to include('ig-tour-tooltip')
      end
    end

    context 'when the user has already completed the walkthrough' do
      let(:user) { create(:user, account: account, walkthrough_completed_at: 1.day.ago) }

      before { sign_in user }

      it 'does not include the tour markup' do
        get agreements_path
        expect(response).to have_http_status(:ok)
        expect(response.body).not_to include('ig-tour-tooltip')
      end

      it 'includes the tour markup when ?tour=true is passed' do
        get agreements_path(tour: 'true')
        expect(response.body).to include('ig-tour-tooltip')
      end
    end
  end
end
