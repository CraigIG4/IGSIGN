# frozen_string_literal: true

require 'rails_helper'

RSpec.describe 'Admin::ApprovalMatrices', type: :request do
  let(:admin_user) { create(:user, role: User::ADMIN_ROLE) }
  let(:regular_user) { create(:user, role: 'viewer') }
  let(:account) { admin_user.account }

  let!(:matrix) do
    create(:caf_approval_matrix,
           account:         account,
           name:            'Test NDA Matrix',
           agreement_types: ['nda'],
           active:          true)
  end

  def valid_params(overrides = {})
    {
      caf_approval_matrix: {
        name:            'New Matrix',
        agreement_types: ['msa'],
        # entity_scope intentionally omitted — nil means "all entities".
        # Passing [] encodes as entity_scope[]= in Rack, which Rails parses as [""],
        # causing entity_scope_valid to reject the blank string as an unknown entity.
        value_threshold: '',
        stages_config:   [
          {
            name:                       'Internal Approval',
            routing:                    'ordered',
            required_roles:             ['CLO', 'CEO'],
            strip_internal_on_complete: 'true'
          }
        ]
      }.merge(overrides)
    }
  end

  # ── Index ────────────────────────────────────────────────────────────────────

  describe 'GET /admin/approval_matrices' do
    context 'as admin' do
      before { sign_in admin_user }

      it 'returns 200 and lists matrices' do
        get admin_approval_matrices_path
        expect(response).to have_http_status(:ok)
        expect(response.body).to include('Test NDA Matrix')
      end
    end

    context 'as non-admin' do
      before { sign_in regular_user }

      it 'redirects to root' do
        get admin_approval_matrices_path
        expect(response).to redirect_to(root_path)
      end
    end

    context 'unauthenticated' do
      it 'redirects to sign-in' do
        get admin_approval_matrices_path
        expect(response).to redirect_to(new_user_session_path)
      end
    end
  end

  # ── New ──────────────────────────────────────────────────────────────────────

  describe 'GET /admin/approval_matrices/new' do
    before { sign_in admin_user }

    it 'returns 200' do
      get new_admin_approval_matrix_path
      expect(response).to have_http_status(:ok)
    end
  end

  # ── Create ───────────────────────────────────────────────────────────────────

  describe 'POST /admin/approval_matrices' do
    before { sign_in admin_user }

    context 'with valid params' do
      it 'creates a matrix and redirects' do
        expect {
          post admin_approval_matrices_path, params: valid_params
        }.to change(CafApprovalMatrix, :count).by(1)

        expect(response).to redirect_to(admin_approval_matrices_path)
      end

      it 'creates a MATRIX_CREATED audit event' do
        expect {
          post admin_approval_matrices_path, params: valid_params
        }.to change(MatrixAuditEvent, :count).by(1)

        expect(MatrixAuditEvent.last.event_type).to eq('MATRIX_CREATED')
        expect(MatrixAuditEvent.last.user_id).to eq(admin_user.id)
      end

      it 'scopes the matrix to the current account' do
        post admin_approval_matrices_path, params: valid_params
        created = CafApprovalMatrix.last
        expect(created.account_id).to eq(account.id)
      end
    end

    context 'with invalid params (missing name)' do
      it 're-renders new with 422' do
        post admin_approval_matrices_path,
             params: valid_params(name: '')
        expect(response).to have_http_status(:unprocessable_entity)
      end
    end
  end

  # ── Edit ─────────────────────────────────────────────────────────────────────

  describe 'GET /admin/approval_matrices/:id/edit' do
    before { sign_in admin_user }

    it 'returns 200 and shows the form' do
      get edit_admin_approval_matrix_path(matrix)
      expect(response).to have_http_status(:ok)
      expect(response.body).to include('Test NDA Matrix')
    end

    it 'raises 404 for a matrix belonging to another account' do
      other_user   = create(:user)
      other_matrix = create(:caf_approval_matrix, account: other_user.account)
      expect {
        get edit_admin_approval_matrix_path(other_matrix)
      }.to raise_error(ActiveRecord::RecordNotFound)
    end
  end

  # ── Update ───────────────────────────────────────────────────────────────────

  describe 'PATCH /admin/approval_matrices/:id' do
    before { sign_in admin_user }

    it 'updates the matrix and redirects' do
      patch admin_approval_matrix_path(matrix),
            params: valid_params(name: 'Updated Matrix')
      expect(response).to redirect_to(admin_approval_matrices_path)
      expect(matrix.reload.name).to eq('Updated Matrix')
    end

    it 'creates a MATRIX_UPDATED audit event' do
      expect {
        patch admin_approval_matrix_path(matrix), params: valid_params(name: 'Updated')
      }.to change { MatrixAuditEvent.where(event_type: 'MATRIX_UPDATED').count }.by(1)
    end

    it 're-renders edit with 422 on invalid params' do
      patch admin_approval_matrix_path(matrix),
            params: valid_params(name: '', agreement_types: [])
      expect(response).to have_http_status(:unprocessable_entity)
    end
  end

  # ── Deactivate ───────────────────────────────────────────────────────────────

  describe 'PATCH /admin/approval_matrices/:id/deactivate' do
    before { sign_in admin_user }

    it 'sets matrix to inactive and redirects' do
      patch deactivate_admin_approval_matrix_path(matrix)
      expect(response).to redirect_to(admin_approval_matrices_path)
      expect(matrix.reload.active).to be(false)
    end

    it 'creates a MATRIX_DEACTIVATED audit event' do
      expect {
        patch deactivate_admin_approval_matrix_path(matrix)
      }.to change { MatrixAuditEvent.where(event_type: 'MATRIX_DEACTIVATED').count }.by(1)
    end

    it 'redirects with alert when already inactive' do
      matrix.update!(active: false)
      patch deactivate_admin_approval_matrix_path(matrix)
      expect(response).to redirect_to(admin_approval_matrices_path)
      follow_redirect!
      expect(response.body).to match(/already inactive/i)
    end

    context 'as non-admin' do
      before { sign_in regular_user }

      it 'redirects to root without deactivating' do
        patch deactivate_admin_approval_matrix_path(matrix)
        expect(response).to redirect_to(root_path)
        expect(matrix.reload.active).to be(true)
      end
    end
  end
end
