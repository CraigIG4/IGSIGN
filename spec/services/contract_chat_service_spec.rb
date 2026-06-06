# frozen_string_literal: true

require 'rails_helper'

RSpec.describe ContractChatService, type: :model do
  let(:account)  { create(:account) }
  let(:user)     { create(:user, account: account) }
  let(:workflow) { create(:caf_workflow, account: account, created_by_user: user) }

  # Build a submitter double with a controllable stage position
  def make_submitter(stage_position:, submission_id: 1)
    stage = instance_double(CafStage, position: stage_position)
    submission = instance_double(Submission, id: submission_id)
    allow(submission).to receive(:caf_stages).and_return(
      double('stages_proxy', joins: double('joined', find_by: stage))
    )
    instance_double(
      Submitter,
      id: 42,
      slug: 'test-slug-123',
      submission_id: submission_id,
      submission: submission
    )
  end

  describe '#answer — internal_signer? gate' do
    context 'when submitter is Stage 2 (counterparty, position >= 2)' do
      let(:submitter) { make_submitter(stage_position: 2) }

      it 'returns error without calling the LLM' do
        expect(IgsignLlmClient).not_to receive(:chat)
        result = described_class.answer(
          question: 'What is the notice period?',
          caf_workflow_id: workflow.id,
          submitter: submitter
        )
        expect(result).to eq({ error: 'Not available' })
      end
    end

    context 'when submitter is Stage 0 (internal, position 0)' do
      let(:submitter) { make_submitter(stage_position: 0) }

      before do
        allow(IgsignLlmClient).to receive(:configured?).and_return(false)
      end

      it 'passes the internal_signer? check and proceeds' do
        result = described_class.answer(
          question: 'What is the value?',
          caf_workflow_id: workflow.id,
          submitter: submitter
        )
        # Fails at AI key check, not at stage check
        expect(result).to eq({ error: 'AI_API_KEY not configured' })
      end
    end

    context 'when submitter is Stage 1 (executive, position 1)' do
      let(:submitter) { make_submitter(stage_position: 1) }

      before do
        allow(IgsignLlmClient).to receive(:configured?).and_return(false)
      end

      it 'passes the internal_signer? check' do
        result = described_class.answer(
          question: 'Summarise the liability terms',
          caf_workflow_id: workflow.id,
          submitter: submitter
        )
        expect(result).to eq({ error: 'AI_API_KEY not configured' })
      end
    end
  end

  describe '#answer — full flow with AI' do
    let(:submitter) { make_submitter(stage_position: 0) }

    before do
      allow(IgsignLlmClient).to receive(:configured?).and_return(true)
      allow(IgsignLlmClient).to receive(:chat).and_return('The notice period is 30 days.')
      # Stub text extraction so no blob download is needed
      allow_any_instance_of(described_class).to receive(:extract_text).and_return('Contract text here.')
    end

    it 'returns an answer hash' do
      result = described_class.answer(
        question: 'What is the notice period?',
        caf_workflow_id: workflow.id,
        submitter: submitter
      )
      expect(result[:answer]).to eq('The notice period is 30 days.')
    end

    it 'writes a ChatAuditLog record' do
      expect {
        described_class.answer(
          question: 'What is the notice period?',
          caf_workflow_id: workflow.id,
          submitter: submitter
        )
      }.to change(ChatAuditLog, :count).by(1)
    end

    it 'stores a SHA-256 digest, not the raw slug' do
      described_class.answer(
        question: 'What is the liability cap?',
        caf_workflow_id: workflow.id,
        submitter: submitter
      )
      log = ChatAuditLog.last
      expect(log.submitter_token_digest).to eq(Digest::SHA256.hexdigest('test-slug-123'))
      expect(log.submitter_token_digest).not_to eq('test-slug-123')
    end

    it 'audit log failure does not raise' do
      allow(ChatAuditLog).to receive(:create!).and_raise(ActiveRecord::RecordInvalid)
      expect {
        described_class.answer(
          question: 'What is the payment term?',
          caf_workflow_id: workflow.id,
          submitter: submitter
        )
      }.not_to raise_error
    end
  end

  describe '#answer — context assembly' do
    let(:submitter) { make_submitter(stage_position: 0) }

    before do
      allow(IgsignLlmClient).to receive(:configured?).and_return(true)
    end

    it 'returns error when no document text is available' do
      allow_any_instance_of(described_class).to receive(:extract_text).and_return('')
      allow(IgsignLlmClient).to receive(:chat)

      result = described_class.answer(
        question: 'What is the term?',
        caf_workflow_id: workflow.id,
        submitter: submitter
      )
      expect(result[:error]).to include('No document text')
      expect(IgsignLlmClient).not_to have_received(:chat)
    end
  end
end
