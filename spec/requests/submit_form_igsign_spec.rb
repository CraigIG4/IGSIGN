# frozen_string_literal: true

require 'rails_helper'

# Tests for IGSIGN enhancements to the counterparty signing flow:
#   - Welcome overlay markup
#   - Progress banner markup
#   - Help panel markup
#   - Completed page "emailed to" and "what happens next" sections
RSpec.describe 'Submit form — IGSIGN counterparty UX', type: :request do
  let(:account)    { create(:account) }
  let(:author)     { create(:user, account: account) }
  let(:template)   { create(:template, account: account, author: author) }
  let(:submission) { create(:submission, account: account, template: template, created_by_user: author) }
  let(:submitter)  { create(:submitter, submission: submission, account: account, email: 'cp@example.com') }

  describe 'GET /s/:slug (signing page)' do
    before do
      # Ensure submitter has a slug
      submitter.update_columns(slug: 'testslug123', completed_at: nil)
    end

    it 'renders the welcome overlay' do
      get submit_form_path(submitter.slug)
      expect(response).to have_http_status(:ok)
      expect(response.body).to include('ig-welcome-overlay')
    end

    it 'includes dismiss controls for the welcome overlay' do
      get submit_form_path(submitter.slug)
      expect(response.body).to include('ig-welcome-continue')
      expect(response.body).to include('ig-welcome-skip')
      expect(response.body).to include('ig-welcome-close')
    end

    it 'includes the Skip intro button' do
      get submit_form_path(submitter.slug)
      expect(response.body).to include('Skip intro')
    end

    it 'includes the three-step How it works section' do
      get submit_form_path(submitter.slug)
      expect(response.body).to include('How it works')
      expect(response.body).to include('Review')
      expect(response.body).to include('Sign')
      expect(response.body).to include('Download your copy')
    end

    it 'includes the help panel' do
      get submit_form_path(submitter.slug)
      expect(response.body).to include('ig-help-panel')
      expect(response.body).to include('How to sign')
    end
  end

  describe 'GET /s/:slug/completed' do
    before do
      submitter.update_columns(
        slug:         'testslug456',
        completed_at: 10.minutes.ago,
        email:        'cp@example.com'
      )
    end

    it 'shows the emailed-to notice with counterparty email' do
      get completed_submit_form_path(submitter.slug)
      expect(response).to have_http_status(:ok)
      expect(response.body).to include('cp@example.com')
      expect(response.body).to include('signed copy has been emailed')
    end

    it 'shows the "what happens next" section' do
      get completed_submit_form_path(submitter.slug)
      expect(response.body).to include('What happens next')
      expect(response.body).to include('Ignition Group will receive')
    end
  end
end
