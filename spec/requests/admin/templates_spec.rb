# frozen_string_literal: true

require 'rails_helper'

RSpec.describe 'Admin::Templates', type: :request do
  let(:admin)   { create(:user, role: User::ADMIN_ROLE) }
  let(:viewer)  { create(:user) }
  let(:account) { admin.account }

  let!(:template) { create(:template, author: admin, account: account) }

  def valid_meta_params(overrides = {})
    { igsign_template_metadata: { kind: 'nda', owner_id: admin.id, status: 'draft', notes: '' }.merge(overrides) }
  end

  # ── Index ────────────────────────────────────────────────────────────────────

  describe 'GET /admin/templates' do
    context 'as admin' do
      before { sign_in admin }

      it 'returns 200 and lists templates' do
        get admin_templates_path
        expect(response).to have_http_status(:ok)
        expect(response.body).to include(template.name)
      end
    end

    context 'as non-admin' do
      before { sign_in viewer }

      it 'redirects to root' do
        get admin_templates_path
        expect(response).to redirect_to(root_path)
      end
    end

    context 'unauthenticated' do
      it 'redirects to sign in' do
        get admin_templates_path
        expect(response).to redirect_to(new_user_session_path)
      end
    end
  end

  # ── Edit metadata ────────────────────────────────────────────────────────────

  describe 'GET /admin/templates/:id/edit' do
    before { sign_in admin }

    it 'returns 200' do
      get edit_admin_template_path(template)
      expect(response).to have_http_status(:ok)
      expect(response.body).to include(template.name)
    end

    it 'raises 404 for template belonging to another account' do
      other = create(:template, author: create(:user))
      expect { get edit_admin_template_path(other) }.to raise_error(ActiveRecord::RecordNotFound)
    end
  end

  # ── Create metadata ──────────────────────────────────────────────────────────

  describe 'POST /admin/templates' do
    before { sign_in admin }

    it 'creates metadata and redirects' do
      expect {
        post admin_templates_path,
             params: valid_meta_params.merge(template_id: template.id)
      }.to change(IgsignTemplateMetadata, :count).by(1)

      expect(response).to redirect_to(admin_templates_path)
    end

    it 'scopes metadata to the correct template' do
      post admin_templates_path,
           params: valid_meta_params.merge(template_id: template.id)
      expect(IgsignTemplateMetadata.last.template_id).to eq(template.id)
    end
  end

  # ── Update metadata ──────────────────────────────────────────────────────────

  describe 'PATCH /admin/templates/:id' do
    let!(:meta) { create(:igsign_template_metadata, template: template, owner: admin, kind: 'nda', status: 'draft') }

    before { sign_in admin }

    it 'updates the metadata and redirects' do
      patch admin_template_path(template),
            params: valid_meta_params(kind: 'msa')
      expect(response).to redirect_to(admin_templates_path)
      expect(meta.reload.kind).to eq('msa')
    end

    it 'bumps version when updating an active record' do
      meta.update!(status: 'active')
      expect {
        patch admin_template_path(template), params: valid_meta_params(status: 'active')
      }.to change { meta.reload.version }.by(1)
    end

    it 'does not bump version on draft update' do
      expect {
        patch admin_template_path(template), params: valid_meta_params(status: 'draft')
      }.not_to(change { meta.reload.version })
    end

    it 'returns 422 on invalid params' do
      patch admin_template_path(template),
            params: valid_meta_params(kind: 'fake_type')
      expect(response).to have_http_status(:unprocessable_entity)
    end
  end

  # ── Activate ─────────────────────────────────────────────────────────────────

  describe 'PATCH /admin/templates/:id/activate' do
    let!(:meta) { create(:igsign_template_metadata, template: template, owner: admin, status: 'draft') }

    before { sign_in admin }

    it 'sets status to active and redirects' do
      patch activate_admin_template_path(template)
      expect(response).to redirect_to(admin_templates_path)
      expect(meta.reload.status).to eq('active')
    end
  end

  # ── Deprecate ────────────────────────────────────────────────────────────────

  describe 'PATCH /admin/templates/:id/deprecate' do
    let!(:meta) { create(:igsign_template_metadata, template: template, owner: admin, status: 'active') }

    before { sign_in admin }

    it 'sets status to deprecated and redirects' do
      patch deprecate_admin_template_path(template)
      expect(response).to redirect_to(admin_templates_path)
      expect(meta.reload.status).to eq('deprecated')
    end

    context 'as non-admin' do
      before { sign_in viewer }

      it 'redirects to root without changing status' do
        patch deprecate_admin_template_path(template)
        expect(response).to redirect_to(root_path)
        expect(meta.reload.status).to eq('active')
      end
    end
  end
end
