# frozen_string_literal: true

require 'rails_helper'

RSpec.describe 'Profile tour completion', type: :request do
  let(:account) { create(:account) }
  let(:user)    { create(:user, account: account, walkthrough_completed_at: nil) }

  before { sign_in user }

  describe 'PATCH /settings/profile/complete_tour' do
    it 'sets walkthrough_completed_at and returns JSON ok' do
      expect {
        patch complete_tour_settings_profile_index_path,
              headers: { 'Accept' => 'application/json', 'Content-Type' => 'application/json' }
      }.to change { user.reload.walkthrough_completed_at }.from(nil)

      expect(response).to have_http_status(:ok)
      expect(JSON.parse(response.body)).to eq('ok' => true)
    end

    it 'is idempotent — calling twice does not raise' do
      user.update_column(:walkthrough_completed_at, 1.day.ago)

      patch complete_tour_settings_profile_index_path,
            headers: { 'Accept' => 'application/json', 'Content-Type' => 'application/json' }

      expect(response).to have_http_status(:ok)
    end

    it 'requires authentication' do
      sign_out user
      patch complete_tour_settings_profile_index_path,
            headers: { 'Accept' => 'application/json' }
      # Devise redirects unauthenticated requests; not a 200 OK
      expect(response).not_to have_http_status(:ok)
    end
  end
end
