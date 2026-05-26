# frozen_string_literal: true

require 'rails_helper'

# ── Stage layout helper ───────────────────────────────────────────────────────
#
# Calls CafSubmissionCreator with document-generation methods stubbed so we can
# assert on the resulting CafStage records without needing LibreOffice or blobs.
#
# Template creation and signatory/stage DB writes run normally.
module CafSubmissionCreatorSpecHelpers
  def run_creator(workflow, user)
    allow(CafApprovalMatrix).to receive(:resolve_for).and_return(nil)
    allow(CafApprovalMatrix).to receive(:for).and_return(nil)

    creator = CafSubmissionCreator.new(workflow, user)
    allow(creator).to receive(:attach_caf_pdf_document)
    allow(creator).to receive(:attach_contract_document)
    allow(creator).to receive(:attach_nda_agreement_document)
    allow(creator).to receive(:merge_agreement_template_fields!)
    allow(creator).to receive(:extend_submission_schema)

    result = creator.call
    raise result[:error] unless result[:success]

    result[:submission]
  end
end

RSpec.describe CafSubmissionCreator, type: :model do
  include CafSubmissionCreatorSpecHelpers

  # Load the canonical signatory registry once for this example group.
  # The registry seed is idempotent so repeated runs are safe.
  before(:all) do
    load Rails.root.join('db/seeds/igsign_registry.rb')
  end

  let(:account) { create(:account) }
  let(:user)    { create(:user, account: account) }

  # ── Shared helpers ───────────────────────────────────────────────────────────

  def stage_at(submission, position)
    submission.caf_stages.find_by!(position: position)
  end

  def emails_at_stage(submission, position)
    stage_at(submission, position).submitters.map(&:email).sort
  end

  def make_workflow(entity:, agreement_type:, commercial_relationship: 0)
    wf = build(:caf_workflow,
               account:                 account,
               created_by_user:         user,
               entity:                  entity,
               agreement_type:          agreement_type,
               commercial_relationship: commercial_relationship,
               counterparty_email:      'cp@example.com',
               status:                  'draft')
    wf.save!
    wf.auto_assign_signatories!
    wf.save!
    wf
  end

  # ── Guard: empty stages_config ────────────────────────────────────────────────

  describe '#call — empty stages guard' do
    let(:workflow) { make_workflow(entity: 'iti', agreement_type: 'msa') }

    before do
      allow(CafApprovalMatrix).to receive(:resolve_for).and_return(nil)
      allow(CafApprovalMatrix).to receive(:for).and_return(nil)
      allow_any_instance_of(described_class).to receive(:build_default_stages)
      allow_any_instance_of(described_class).to receive(:attach_caf_pdf_document)
      allow_any_instance_of(described_class).to receive(:attach_contract_document)
      allow_any_instance_of(described_class).to receive(:merge_agreement_template_fields!)
      allow_any_instance_of(described_class).to receive(:extend_submission_schema)
    end

    it 'returns an error hash instead of raising uncaught' do
      result = described_class.new(workflow, user).call
      expect(result[:success]).to be false
      expect(result[:error]).to match(/No approval stages/i)
    end
  end

  # ── Stage 2: multi-stage routing ─────────────────────────────────────────────
  #
  # HARD GATE 2 — Five canonical scenario traces:
  #
  # 1. ITI customer MSA
  #    Stage 0 (parallel, strip=false): William Talbot (bu_head),
  #                                     Laren Farquharson (bu_cfo),
  #                                     Craig G. Lawrence (group_clo),
  #                                     Laren Farquharson (group_cfo) [⚠ Laren ×2 for ITI]
  #    Stage 1 (ordered, strip=false): Sean Bergsma (group_signer)
  #    Stage 2 (ordered, strip=true):  Donovan Bergsma (group_signer_alt)
  #    Stage 3 (counterparty)
  #
  # 2. Comit supplier vendor agreement
  #    Stage 0 (parallel, strip=false): Mark Mitchell (bu_head),
  #                                     Verona Naidoo (bu_cfo),
  #                                     Daniel Schauffer (bu_cfo_alternate),
  #                                     Craig G. Lawrence (group_clo),
  #                                     Laren Farquharson (group_cfo),
  #                                     Callie Baney (procurement)
  #    Stage 1 (ordered, strip=true): Sean Bergsma (group_signer)
  #    Stage 2 (counterparty)
  #
  # 3. Spot Connect customer SLA (4-stage: Siddeek → Sean)
  #    Stage 0 (parallel, strip=false): Ivor vonNielen (bu_head),
  #                                     Nikola Ramsden (bu_cfo),
  #                                     Craig G. Lawrence (group_clo),
  #                                     Laren Farquharson (group_cfo)
  #    Stage 1 (ordered, strip=false): Siddeek Rahim (group_signer)
  #    Stage 2 (ordered, strip=true):  Sean Bergsma (group_signer_alt)
  #    Stage 3 (counterparty)
  #
  # 4. IFS supplier vendor agreement (Kobus double-signs)
  #    Stage 0 (parallel, strip=false): Kobus Botha (bu_head),
  #                                     Angeline Bennett (bu_cfo),
  #                                     Craig G. Lawrence (group_clo),
  #                                     Laren Farquharson (group_cfo),
  #                                     Callie Baney (procurement),
  #                                     Sean Bergsma (approver_only)
  #    Stage 1 (ordered, strip=true): Kobus Botha (group_signer)
  #    Stage 2 (counterparty)
  #
  # 5. ITI NDA (Craig alone → counterparty)
  #    Stage 0 (parallel, strip=true): Craig G. Lawrence (group_clo)
  #    Stage 1 (counterparty)

  describe 'Scenario 1 — ITI customer MSA' do
    let(:submission) { run_creator(make_workflow(entity: 'iti', agreement_type: 'msa', commercial_relationship: 0), user) }

    it 'creates 4 stages' do
      expect(submission.caf_stages.count).to eq(4)
    end

    it 'Stage 0 is parallel, not stripping' do
      s0 = stage_at(submission, 0)
      expect(s0.routing).to eq('parallel')
      expect(s0.strip_internal_on_complete).to be(false)
    end

    it 'Stage 0 includes William Talbot and Craig Lawrence' do
      emails = emails_at_stage(submission, 0)
      expect(emails).to include('William.Talbot@ignitiongroup.co.za')
      expect(emails).to include('Clawre969@ignitiongroup.co.za')
    end

    it 'Stage 0 excludes Callie Baney (customer, not supplier)' do
      expect(emails_at_stage(submission, 0)).not_to include('Callie.Baney@ignitiongroup.co.za')
    end

    it 'Stage 1 is Sean Bergsma (group_signer), ordered, not stripping' do
      s1 = stage_at(submission, 1)
      expect(s1.routing).to eq('ordered')
      expect(s1.strip_internal_on_complete).to be(false)
      expect(emails_at_stage(submission, 1)).to eq(['Sean.Bergsma@ignitiongroup.co.za'])
    end

    it 'Stage 2 is Donovan Bergsma (group_signer_alt), ordered, strips' do
      s2 = stage_at(submission, 2)
      expect(s2.routing).to eq('ordered')
      expect(s2.strip_internal_on_complete).to be(true)
      expect(emails_at_stage(submission, 2)).to eq(['Donovan.Bergsma@ignitiongroup.co.za'])
    end

    it 'Stage 3 is Counterparty Signing, pending, no submitters' do
      s3 = stage_at(submission, 3)
      expect(s3.name).to eq('Counterparty Signing')
      expect(s3.status).to eq('pending')
      expect(s3.caf_stage_submitters).to be_empty
    end
  end

  describe 'Scenario 2 — Comit supplier vendor agreement' do
    let(:submission) { run_creator(make_workflow(entity: 'comit', agreement_type: 'vendor', commercial_relationship: 1), user) }

    it 'creates 3 stages (internal + group signer + counterparty)' do
      expect(submission.caf_stages.count).to eq(3)
    end

    it 'Stage 0 includes Callie Baney (supplier procurement)' do
      expect(emails_at_stage(submission, 0)).to include('Callie.Baney@ignitiongroup.co.za')
    end

    it 'Stage 0 includes Daniel Schauffer (bu_cfo_alternate)' do
      expect(emails_at_stage(submission, 0)).to include('Daniel.Schauffer@ignitiongroup.co.za')
    end

    it 'Stage 1 is Sean Bergsma (group_signer), strips on complete' do
      s1 = stage_at(submission, 1)
      expect(s1.strip_internal_on_complete).to be(true)
      expect(emails_at_stage(submission, 1)).to eq(['Sean.Bergsma@ignitiongroup.co.za'])
    end

    it 'Stage 2 is Counterparty Signing' do
      expect(stage_at(submission, 2).name).to eq('Counterparty Signing')
    end
  end

  describe 'Scenario 3 — Spot Connect customer SLA' do
    let(:submission) { run_creator(make_workflow(entity: 'spot_connect', agreement_type: 'sla', commercial_relationship: 0), user) }

    it 'creates 4 stages (Stage 0 + Siddeek + Sean + Counterparty)' do
      expect(submission.caf_stages.count).to eq(4)
    end

    it 'Stage 1 is Siddeek Rahim (group_signer), ordered, NOT stripping' do
      s1 = stage_at(submission, 1)
      expect(s1.routing).to eq('ordered')
      expect(s1.strip_internal_on_complete).to be(false)
      expect(emails_at_stage(submission, 1)).to eq(['siddeek.rahim@uconnect.co.za'])
    end

    it 'Stage 2 is Sean Bergsma (group_signer_alt), ordered, strips' do
      s2 = stage_at(submission, 2)
      expect(s2.routing).to eq('ordered')
      expect(s2.strip_internal_on_complete).to be(true)
      expect(emails_at_stage(submission, 2)).to eq(['Sean.Bergsma@ignitiongroup.co.za'])
    end

    it 'Stage 0 excludes Callie Baney (customer, not supplier)' do
      expect(emails_at_stage(submission, 0)).not_to include('Callie.Baney@ignitiongroup.co.za')
    end

    it 'Stage 3 is Counterparty Signing' do
      expect(stage_at(submission, 3).name).to eq('Counterparty Signing')
    end
  end

  describe 'Scenario 4 — IFS supplier vendor agreement' do
    let(:submission) { run_creator(make_workflow(entity: 'ifs', agreement_type: 'vendor', commercial_relationship: 1), user) }

    it 'creates 3 stages (internal + Kobus group signer + counterparty)' do
      expect(submission.caf_stages.count).to eq(3)
    end

    it 'Stage 0 includes Sean Bergsma as approver_only (Stage 0 only for IFS)' do
      expect(emails_at_stage(submission, 0)).to include('Sean.Bergsma@ignitiongroup.co.za')
    end

    it 'Stage 0 includes Callie Baney (supplier)' do
      expect(emails_at_stage(submission, 0)).to include('Callie.Baney@ignitiongroup.co.za')
    end

    it 'Stage 1 is Kobus Botha only (IFS group_signer exception), strips' do
      s1 = stage_at(submission, 1)
      expect(s1.strip_internal_on_complete).to be(true)
      expect(emails_at_stage(submission, 1)).to eq(['kobus.botha@igfs.co.za'])
    end

    it 'Stage 1 does NOT include Sean Bergsma (Sean is approver_only, not group_signer for IFS)' do
      expect(emails_at_stage(submission, 1)).not_to include('Sean.Bergsma@ignitiongroup.co.za')
    end

    it 'Stage 2 is Counterparty Signing' do
      expect(stage_at(submission, 2).name).to eq('Counterparty Signing')
    end
  end

  describe 'Scenario 5 — ITI NDA (Craig alone → counterparty)' do
    let(:submission) { run_creator(make_workflow(entity: 'iti', agreement_type: 'nda'), user) }

    it 'creates exactly 2 stages (no group signer stage for NDA)' do
      expect(submission.caf_stages.count).to eq(2)
    end

    it 'Stage 0 is parallel, strips on complete (last and only internal stage)' do
      s0 = stage_at(submission, 0)
      expect(s0.routing).to eq('parallel')
      expect(s0.strip_internal_on_complete).to be(true)
    end

    it 'Stage 0 contains only Craig G. Lawrence (group_clo)' do
      expect(emails_at_stage(submission, 0)).to eq(['Clawre969@ignitiongroup.co.za'])
    end

    it 'Stage 0 does not include BU heads or group signers' do
      emails = emails_at_stage(submission, 0)
      expect(emails).not_to include('William.Talbot@ignitiongroup.co.za')
      expect(emails).not_to include('Sean.Bergsma@ignitiongroup.co.za')
      expect(emails).not_to include('Donovan.Bergsma@ignitiongroup.co.za')
    end

    it 'Stage 1 is Counterparty Signing (no intermediate group signer)' do
      expect(stage_at(submission, 1).name).to eq('Counterparty Signing')
    end
  end

  # ── commercial_relationship enum ─────────────────────────────────────────────

  describe 'CafWorkflow#commercial_relationship enum' do
    it 'defaults to customer' do
      wf = build(:caf_workflow, account: account, created_by_user: user)
      expect(wf.commercial_relationship).to eq('customer')
      expect(wf.commercial_customer?).to be(true)
      expect(wf.commercial_supplier?).to be(false)
    end

    it 'accepts supplier (integer 1)' do
      wf = build(:caf_workflow, account: account, created_by_user: user, commercial_relationship: 1)
      expect(wf.commercial_supplier?).to be(true)
      expect(wf.commercial_customer?).to be(false)
    end
  end
end
