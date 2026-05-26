# frozen_string_literal: true

require 'rails_helper'

RSpec.describe CafWebhookHandler, type: :model do
  let(:account)      { create(:account) }
  let(:user)         { create(:user, account: account) }
  let(:submission)   { create(:submission, account: account) }
  let(:caf_workflow) { create(:caf_workflow, account: account, created_by_user: user, caf_submission: submission) }

  subject { described_class.new(submission) }

  before do
    allow(subject).to receive(:find_caf_workflow).and_return(caf_workflow)
    allow(caf_workflow).to receive(:caf_submission).and_return(submission)
  end

  def make_stage(position:, status: 'active', name: nil)
    name ||= position == :last ? 'Counterparty Signing' : 'Internal CAF Approval'
    instance_double(
      CafStage,
      id:                         position,
      position:                   position,
      status:                     status,
      name:                       name,
      all_submitters_complete?:   true,
      complete!:                  true
    )
  end

  # ── 2-stage (NDA): Stage 0 (Craig) + Stage 1 (Counterparty) ─────────────────

  context 'NDA-style 2-stage flow' do
    let(:stage0)      { make_stage(position: 0, name: 'Internal CAF Approval') }
    let(:stage1_cp)   { make_stage(position: 1, name: 'Counterparty Signing')  }

    before do
      allow(submission).to receive_message_chain(:caf_stages, :where, :ordered_by_position, :first)
        .and_return(stage0)
      allow(submission).to receive_message_chain(:caf_stages, :ordered_by_position, :to_a)
        .and_return([stage0, stage1_cp])
    end

    it 'fires CafCompletionHandler when Stage 0 (last internal) completes' do
      handler = instance_double(CafCompletionHandler, call: { success: true })
      allow(CafCompletionHandler).to receive(:new).with(caf_workflow).and_return(handler)

      subject.call

      expect(handler).to have_received(:call)
    end
  end

  context 'NDA-style 2-stage flow — counterparty stage' do
    let(:stage0_cp)   { make_stage(position: 0, name: 'Internal CAF Approval', status: 'complete') }
    let(:stage1_cp)   { make_stage(position: 1, name: 'Counterparty Signing') }

    before do
      allow(submission).to receive_message_chain(:caf_stages, :where, :ordered_by_position, :first)
        .and_return(stage1_cp)
      allow(submission).to receive_message_chain(:caf_stages, :ordered_by_position, :to_a)
        .and_return([stage0_cp, stage1_cp])
      allow(stage1_cp).to receive(:submitters).and_return([])
    end

    it 'fires CafAuditBundleSender when counterparty stage (last) completes' do
      sender = instance_double(CafAuditBundleSender, call: nil)
      allow(CafAuditBundleSender).to receive(:new).with(caf_workflow).and_return(sender)
      allow(caf_workflow).to receive(:company_id).and_return(nil)

      subject.call

      expect(sender).to have_received(:call)
    end
  end

  # ── 3-stage (standard): Stage 0 (parallel) + Stage 1 (group signer) + Stage 2 (CP) ──

  context 'standard 3-stage flow — intermediate Stage 0 complete' do
    let(:stage0)      { make_stage(position: 0, name: 'Internal CAF Approval')    }
    let(:stage1_gs)   { make_stage(position: 1, name: 'Group Signer Approval', status: 'pending') }
    let(:stage2_cp)   { make_stage(position: 2, name: 'Counterparty Signing',  status: 'pending') }

    before do
      allow(submission).to receive_message_chain(:caf_stages, :where, :ordered_by_position, :first)
        .and_return(stage0)
      allow(submission).to receive_message_chain(:caf_stages, :ordered_by_position, :to_a)
        .and_return([stage0, stage1_gs, stage2_cp])
    end

    it 'calls stage.complete! (advances to group signer; does NOT fire CafCompletionHandler)' do
      expect(stage0).to receive(:complete!)
      expect(CafCompletionHandler).not_to receive(:new)

      subject.call
    end
  end

  context 'standard 3-stage flow — Stage 1 (group signer = last internal) complete' do
    let(:stage0)      { make_stage(position: 0, name: 'Internal CAF Approval',    status: 'complete') }
    let(:stage1_gs)   { make_stage(position: 1, name: 'Group Signer Approval') }
    let(:stage2_cp)   { make_stage(position: 2, name: 'Counterparty Signing',  status: 'pending') }

    before do
      allow(submission).to receive_message_chain(:caf_stages, :where, :ordered_by_position, :first)
        .and_return(stage1_gs)
      allow(submission).to receive_message_chain(:caf_stages, :ordered_by_position, :to_a)
        .and_return([stage0, stage1_gs, stage2_cp])
    end

    it 'fires CafCompletionHandler' do
      handler = instance_double(CafCompletionHandler, call: { success: true })
      allow(CafCompletionHandler).to receive(:new).with(caf_workflow).and_return(handler)

      subject.call

      expect(handler).to have_received(:call)
    end
  end

  context 'standard 3-stage flow — counterparty stage complete' do
    let(:stage0)      { make_stage(position: 0, status: 'complete') }
    let(:stage1_gs)   { make_stage(position: 1, status: 'complete') }
    let(:stage2_cp)   { make_stage(position: 2, name: 'Counterparty Signing') }

    before do
      allow(submission).to receive_message_chain(:caf_stages, :where, :ordered_by_position, :first)
        .and_return(stage2_cp)
      allow(submission).to receive_message_chain(:caf_stages, :ordered_by_position, :to_a)
        .and_return([stage0, stage1_gs, stage2_cp])
      allow(stage2_cp).to receive(:submitters).and_return([])
      allow(caf_workflow).to receive(:company_id).and_return(nil)
    end

    it 'fires CafAuditBundleSender' do
      sender = instance_double(CafAuditBundleSender, call: nil)
      allow(CafAuditBundleSender).to receive(:new).with(caf_workflow).and_return(sender)

      subject.call

      expect(sender).to have_received(:call)
    end

    it 'does NOT fire CafCompletionHandler' do
      allow(CafAuditBundleSender).to receive(:new).and_return(instance_double(CafAuditBundleSender, call: nil))
      expect(CafCompletionHandler).not_to receive(:new)

      subject.call
    end
  end

  # ── 4-stage (Spot Connect): Stage 0 + Siddeek + Sean + Counterparty ──────────

  context 'Spot Connect 4-stage flow — Stage 0 (intermediate) complete' do
    let(:stage0)     { make_stage(position: 0, name: 'Internal CAF Approval') }
    let(:stage1_sid) { make_stage(position: 1, name: 'Group Signer Approval',  status: 'pending') }
    let(:stage2_sea) { make_stage(position: 2, name: 'Group Signer Approval',  status: 'pending') }
    let(:stage3_cp)  { make_stage(position: 3, name: 'Counterparty Signing',   status: 'pending') }

    before do
      allow(submission).to receive_message_chain(:caf_stages, :where, :ordered_by_position, :first)
        .and_return(stage0)
      allow(submission).to receive_message_chain(:caf_stages, :ordered_by_position, :to_a)
        .and_return([stage0, stage1_sid, stage2_sea, stage3_cp])
    end

    it 'calls stage.complete! only (intermediate stage — not last internal)' do
      expect(stage0).to receive(:complete!)
      expect(CafCompletionHandler).not_to receive(:new)
      expect(CafAuditBundleSender).not_to receive(:new)

      subject.call
    end
  end

  context 'Spot Connect 4-stage flow — Stage 1 (Siddeek, intermediate) complete' do
    let(:stage0)     { make_stage(position: 0, status: 'complete') }
    let(:stage1_sid) { make_stage(position: 1, name: 'Group Signer Approval') }
    let(:stage2_sea) { make_stage(position: 2, name: 'Group Signer Approval',  status: 'pending') }
    let(:stage3_cp)  { make_stage(position: 3, name: 'Counterparty Signing',   status: 'pending') }

    before do
      allow(submission).to receive_message_chain(:caf_stages, :where, :ordered_by_position, :first)
        .and_return(stage1_sid)
      allow(submission).to receive_message_chain(:caf_stages, :ordered_by_position, :to_a)
        .and_return([stage0, stage1_sid, stage2_sea, stage3_cp])
    end

    it 'calls stage.complete! only (Siddeek stage is intermediate, Sean still follows)' do
      expect(stage1_sid).to receive(:complete!)
      expect(CafCompletionHandler).not_to receive(:new)

      subject.call
    end
  end

  context 'Spot Connect 4-stage flow — Stage 2 (Sean = last internal) complete' do
    let(:stage0)     { make_stage(position: 0, status: 'complete') }
    let(:stage1_sid) { make_stage(position: 1, status: 'complete') }
    let(:stage2_sea) { make_stage(position: 2, name: 'Group Signer Approval') }
    let(:stage3_cp)  { make_stage(position: 3, name: 'Counterparty Signing',   status: 'pending') }

    before do
      allow(submission).to receive_message_chain(:caf_stages, :where, :ordered_by_position, :first)
        .and_return(stage2_sea)
      allow(submission).to receive_message_chain(:caf_stages, :ordered_by_position, :to_a)
        .and_return([stage0, stage1_sid, stage2_sea, stage3_cp])
    end

    it 'fires CafCompletionHandler (Sean is last internal before counterparty)' do
      handler = instance_double(CafCompletionHandler, call: { success: true })
      allow(CafCompletionHandler).to receive(:new).with(caf_workflow).and_return(handler)

      subject.call

      expect(handler).to have_received(:call)
    end
  end

  # ── Early-exit guards ─────────────────────────────────────────────────────────

  it 'returns nil and fires nothing when no CAF workflow found' do
    allow(subject).to receive(:find_caf_workflow).and_return(nil)
    expect(CafCompletionHandler).not_to receive(:new)
    expect { subject.call }.not_to raise_error
  end

  it 'returns nil when stage is not yet fully signed' do
    stage = make_stage(position: 0)
    allow(stage).to receive(:all_submitters_complete?).and_return(false)

    allow(submission).to receive_message_chain(:caf_stages, :where, :ordered_by_position, :first)
      .and_return(stage)
    allow(submission).to receive_message_chain(:caf_stages, :ordered_by_position, :to_a)
      .and_return([stage])

    expect(CafCompletionHandler).not_to receive(:new)
    subject.call
  end
end
