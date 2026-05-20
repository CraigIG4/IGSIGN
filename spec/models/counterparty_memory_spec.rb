# frozen_string_literal: true

# Tests the Counterparty Memory feature end-to-end:
#
#   Company#record_signatory!       — upsert + counter increment
#   Company#recent_signatories      — filtered, ordered list
#   Company#smart_default_signatory — auto-select heuristic
#   CompanySignatory#last_seen_label — presentation helper
#   CafWebhookHandler (position 1)  — records on counterparty completion
#   AgreementsController#recent_signatories — JSON endpoint
#
require 'rails_helper'

RSpec.describe 'Counterparty Memory', type: :request do
  let(:user)    { create(:user) }
  let(:account) { user.account }
  let(:company) { create(:company, account: account) }

  # ── Company#record_signatory! ────────────────────────────────────────────────

  describe 'Company#record_signatory!' do
    context 'first workflow with a new counterparty' do
      it 'creates a CompanySignatory record' do
        expect do
          company.record_signatory!('Alice Dlamini', 'alice@acme.co.za', workflow_id: nil)
        end.to change(CompanySignatory, :count).by(1)
      end

      it 'stores the correct name and email' do
        sig = company.record_signatory!('Alice Dlamini', 'alice@acme.co.za')
        expect(sig.name).to eq('Alice Dlamini')
        expect(sig.email).to eq('alice@acme.co.za')
      end

      it 'sets times_signed to 1' do
        sig = company.record_signatory!('Alice Dlamini', 'alice@acme.co.za')
        expect(sig.times_signed).to eq(1)
      end

      it 'populates first_seen_at and last_seen_at' do
        freeze_time do
          sig = company.record_signatory!('Alice Dlamini', 'alice@acme.co.za')
          expect(sig.first_seen_at).to be_within(1.second).of(Time.current)
          expect(sig.last_seen_at).to be_within(1.second).of(Time.current)
        end
      end

      it 'records the workflow_id on last_workflow_id' do
        wf = create(:caf_workflow, account: account, created_by_user: user)
        sig = company.record_signatory!('Alice Dlamini', 'alice@acme.co.za', workflow_id: wf.id)
        expect(sig.last_workflow_id).to eq(wf.id)
      end
    end

    context 'second workflow with the SAME counterparty email' do
      before { company.record_signatory!('Alice Dlamini', 'alice@acme.co.za') }

      it 'does not create a duplicate record' do
        expect do
          company.record_signatory!('Alice Dlamini', 'alice@acme.co.za')
        end.not_to change(CompanySignatory, :count)
      end

      it 'increments times_signed to 2' do
        sig = company.record_signatory!('Alice Dlamini', 'alice@acme.co.za')
        expect(sig.reload.times_signed).to eq(2)
      end

      it 'updates last_seen_at on the second call' do
        travel_to(1.day.from_now) do
          sig = company.record_signatory!('Alice Dlamini', 'alice@acme.co.za')
          expect(sig.reload.last_seen_at).to be_within(1.second).of(Time.current)
        end
      end

      it 'preserves first_seen_at from the original call' do
        original_time = CompanySignatory.find_by(email: 'alice@acme.co.za').first_seen_at
        travel_to(5.days.from_now) do
          company.record_signatory!('Alice Dlamini', 'alice@acme.co.za')
        end
        expect(CompanySignatory.find_by(email: 'alice@acme.co.za').first_seen_at)
          .to be_within(1.second).of(original_time)
      end

      it 'is case-insensitive on email' do
        expect do
          company.record_signatory!('Alice Dlamini', 'ALICE@ACME.CO.ZA')
        end.not_to change(CompanySignatory, :count)
      end
    end

    context 'edge cases' do
      it 'returns nil without raising when email is blank' do
        expect { company.record_signatory!('Alice', '') }.not_to raise_error
        expect(company.record_signatory!('Alice', '')).to be_nil
      end
    end
  end

  # ── Company#recent_signatories ───────────────────────────────────────────────

  describe 'Company#recent_signatories' do
    let!(:old_sig) do
      create(:company_signatory, company: company, name: 'Old Signer',
                                 email: 'old@acme.co.za', last_seen_at: 60.days.ago, times_signed: 1)
    end
    let!(:new_sig) do
      create(:company_signatory, company: company, name: 'New Signer',
                                 email: 'new@acme.co.za', last_seen_at: 2.days.ago, times_signed: 3)
    end
    let!(:inactive_sig) do
      create(:company_signatory, company: company, name: 'Gone Signer',
                                 email: 'gone@acme.co.za', last_seen_at: 1.day.ago,
                                 times_signed: 5, active: false)
    end

    context 'second workflow with same counterparty' do
      it 'shows the previous signer in the recent signatories list' do
        result = company.recent_signatories
        expect(result.map(&:email)).to include('new@acme.co.za')
      end
    end

    it 'returns active signatories only' do
      result = company.recent_signatories
      expect(result.map(&:email)).not_to include('gone@acme.co.za')
    end

    it 'orders by last_seen_at descending' do
      result = company.recent_signatories
      expect(result.first.email).to eq('new@acme.co.za')
      expect(result.last.email).to eq('old@acme.co.za')
    end

    it 'respects the limit parameter' do
      3.times { |i| create(:company_signatory, company: company, email: "extra#{i}@acme.co.za") }
      expect(company.recent_signatories(limit: 2).count).to eq(2)
    end
  end

  # ── Company#smart_default_signatory ─────────────────────────────────────────

  describe 'Company#smart_default_signatory' do
    context 'when there is exactly one active signatory' do
      before do
        create(:company_signatory, company: company, email: 'only@acme.co.za',
                                   last_seen_at: 5.days.ago)
      end

      it 'returns that signatory' do
        expect(company.smart_default_signatory).not_to be_nil
        expect(company.smart_default_signatory.email).to eq('only@acme.co.za')
      end
    end

    context 'when there are multiple active signatories' do
      before do
        create(:company_signatory, company: company, email: 'a@acme.co.za')
        create(:company_signatory, company: company, email: 'b@acme.co.za')
      end

      it 'returns nil' do
        expect(company.smart_default_signatory).to be_nil
      end
    end

    context 'when there are no active signatories' do
      before do
        create(:company_signatory, company: company, email: 'gone@acme.co.za', active: false)
      end

      it 'returns nil' do
        expect(company.smart_default_signatory).to be_nil
      end
    end
  end

  # ── CompanySignatory#last_seen_label ────────────────────────────────────────

  describe 'CompanySignatory#last_seen_label' do
    subject(:sig) { build(:company_signatory, company: company) }

    it 'returns "Today" when last_seen_at is today' do
      sig.last_seen_at = Time.current
      expect(sig.last_seen_label).to eq('Today')
    end

    it 'returns "Yesterday" when last_seen_at was 1 day ago' do
      sig.last_seen_at = 1.day.ago
      expect(sig.last_seen_label).to eq('Yesterday')
    end

    it 'returns "N days ago" for older dates' do
      sig.last_seen_at = 12.days.ago
      expect(sig.last_seen_label).to eq('12 days ago')
    end

    it 'returns "Never signed" when last_seen_at is nil' do
      sig.last_seen_at = nil
      expect(sig.last_seen_label).to eq('Never signed')
    end
  end

  # ── CafWebhookHandler — signatory recording on counterparty completion ───────

  describe 'CafWebhookHandler records counterparty signatory (position 1)' do
    let(:template)    { create(:template, author: user, account: account) }
    let(:submission)  { create(:submission, template: template, created_by_user: user) }
    let(:workflow) do
      create(:caf_workflow,
             account:          account,
             created_by_user:  user,
             company:          company,
             caf_submission:   submission,
             status:           'sent_counterparty',
             counterparty_email: 'bob@partner.co.za',
             counterparty_name:  'Bob Mokoena')
    end

    let(:stage2) do
      CafStage.create!(
        submission:               submission,
        name:                     'Counterparty Signing',
        position:                 1,
        routing:                  'parallel',
        status:                   'active',
        activated_at:             1.hour.ago,
        strip_internal_on_complete: false
      )
    end

    let(:cp_submitter) do
      create(:submitter,
             submission:   submission,
             account_id:   account.id,
             uuid:         SecureRandom.uuid,
             name:         'Bob Mokoena',
             email:        'bob@partner.co.za',
             completed_at: Time.current)
    end

    before do
      stage2
      CafStageSubmitter.create!(caf_stage: stage2, submitter: cp_submitter, role: 'Counterparty Signatory', position: 0)
      # Stub CafAuditBundleSender so we don't need the full email stack
      allow(CafAuditBundleSender).to receive(:new).and_return(double(call: nil))
    end

    it 'creates a CompanySignatory record for the counterparty' do
      expect do
        CafWebhookHandler.new(submission).call
      end.to change(CompanySignatory, :count).by(1)
    end

    it 'stores the correct name and email' do
      CafWebhookHandler.new(submission).call
      sig = company.company_signatories.last
      expect(sig.name).to  eq('Bob Mokoena')
      expect(sig.email).to eq('bob@partner.co.za')
    end

    it 'still calls CafAuditBundleSender even if signatory recording is skipped (no company)' do
      workflow.update_column(:company_id, nil)
      expect(CafAuditBundleSender).to receive(:new).and_return(double(call: nil))
      CafWebhookHandler.new(submission).call
    end
  end

  # ── AgreementsController#recent_signatories (JSON endpoint) ─────────────────

  describe 'GET /agreements/recent_signatories' do
    let!(:sig1) do
      create(:company_signatory, company: company, name: 'Alice Dlamini',
                                 email: 'alice@acme.co.za', last_seen_at: 3.days.ago,
                                 times_signed: 4, role_title: 'CFO')
    end
    let!(:sig2) do
      create(:company_signatory, company: company, name: 'Bob Mokoena',
                                 email: 'bob@acme.co.za', last_seen_at: 30.days.ago,
                                 times_signed: 1)
    end
    let!(:inactive_sig) do
      create(:company_signatory, company: company, email: 'gone@acme.co.za',
                                 active: false, last_seen_at: 1.day.ago)
    end

    before { sign_in user }

    it 'returns signatories ordered by recency' do
      get recent_signatories_agreements_path(format: :json, company_id: company.id)
      sigs = response.parsed_body['signatories']
      expect(sigs.map { |s| s['email'] }).to eq(%w[alice@acme.co.za bob@acme.co.za])
    end

    it 'excludes inactive signatories' do
      get recent_signatories_agreements_path(format: :json, company_id: company.id)
      emails = response.parsed_body['signatories'].map { |s| s['email'] }
      expect(emails).not_to include('gone@acme.co.za')
    end

    it 'includes last_seen_label, times_signed, and role_title' do
      get recent_signatories_agreements_path(format: :json, company_id: company.id)
      first = response.parsed_body['signatories'].first
      expect(first['last_seen_label']).to be_a(String)
      expect(first['times_signed']).to    eq(4)
      expect(first['role_title']).to      eq('CFO')
    end

    it 'includes smart_default_id when only one recent signatory exists' do
      sig2.update!(active: false) # leave only sig1
      get recent_signatories_agreements_path(format: :json, company_id: company.id)
      expect(response.parsed_body['smart_default_id']).to eq(sig1.id)
    end

    it 'returns smart_default_id: nil when multiple signatories exist' do
      get recent_signatories_agreements_path(format: :json, company_id: company.id)
      expect(response.parsed_body['smart_default_id']).to be_nil
    end

    it 'returns empty signatories for an unknown company_id' do
      get recent_signatories_agreements_path(format: :json, company_id: 0)
      expect(response.parsed_body['signatories']).to eq([])
    end

    it 'returns 200 for a company from a different account' do
      other = create(:company, account: create(:account))
      get recent_signatories_agreements_path(format: :json, company_id: other.id)
      # Should not raise — silently returns empty (company not found in current account)
      expect(response.parsed_body['signatories']).to eq([])
    end
  end
end
