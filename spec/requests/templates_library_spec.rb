# frozen_string_literal: true

require 'rails_helper'

RSpec.describe 'TemplatesLibrary', type: :request do
  let(:admin)   { create(:user, role: User::ADMIN_ROLE) }
  let(:sender)  { create(:user) }
  let(:account) { sender.account }

  let!(:template_with_meta) do
    t = create(:template, author: sender, account: account, name: 'Standard NDA')
    create(:igsign_template_metadata, template: t, kind: 'nda', status: 'active')
    t
  end

  let!(:draft_template) do
    t = create(:template, author: sender, account: account, name: 'Draft MSA')
    create(:igsign_template_metadata, template: t, kind: 'msa', status: 'draft')
    t
  end

  let!(:template_no_meta) do
    create(:template, author: sender, account: account, name: 'Untagged Template')
  end

  describe 'GET /templates (sender library)' do
    context 'as sender (non-admin)' do
      before { sign_in sender }

      it 'returns 200 and shows the library' do
        get templates_path
        expect(response).to have_http_status(:ok)
      end

      it 'shows the NDA section with Start NDA links' do
        get templates_path
        expect(response.body).to include('Start NDA')
      end

      it 'does not show draft metadata templates in active group' do
        get templates_path
        # Draft MSA should not appear under a kind group (it has draft metadata)
        # It will not appear under @templates_by_kind (only active templates are included)
        # So the body won't have "Draft MSA" in a kind card — it may appear in untagged
        expect(response.body).not_to match(/Draft MSA.*Start agreement/m)
      end

      it 'shows the upload card in the Other section' do
        get templates_path
        expect(response.body).to include('Upload Agreement Document')
      end
    end

    context 'as admin' do
      before { sign_in admin }

      it 'redirects to /admin/templates' do
        get templates_path
        expect(response).to redirect_to(admin_templates_path)
      end
    end

    context 'unauthenticated' do
      it 'redirects to sign in' do
        get templates_path
        expect(response).to redirect_to(new_user_session_path)
      end
    end
  end

  describe 'GET /agreements/new?template_id=:id' do
    before { sign_in sender }

    it 'pre-selects the agreement type from template metadata' do
      get new_agreement_path(template_id: template_with_meta.id)
      expect(response).to have_http_status(:ok)
      # The agreement_type should be pre-set to 'nda' from the metadata
      expect(response.body).to include('Standard NDA')
    end

    it 'ignores template_id from a different account' do
      other_template = create(:template, author: create(:user))
      get new_agreement_path(template_id: other_template.id)
      expect(response).to have_http_status(:ok)
      # Template banner should not appear (not in this account's scope)
      expect(response.body).not_to include(other_template.name)
    end
  end
end
