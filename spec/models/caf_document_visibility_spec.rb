# frozen_string_literal: true

# Tests the CAF two-document model:
#
#   * CAF summary PDF   → internal_only: true  (stage 1 only)
#   * Uploaded agreement → internal_only: false (all stages)
#
# Covers:
#   Submission#caf_mixed_schema_documents   — merged template + submission docs
#   Submission#documents_for(submitter)     — per-stage visibility filter
#   CafStage#complete!                      — sets stripped audit marker
#   CafCompletionHandler#call               — records stage_transition_to_counterparty event
#   SubmitFormController (schema filtering) — schema narrowed for stage 2 in memory
#
require 'rails_helper'

RSpec.describe 'CAF document visibility', type: :model do
  # ── Fixtures ────────────────────────────────────────────────────────────────

  let(:user)     { create(:user) }
  let(:account)  { user.account }
  let(:template) { create(:template, author: user, account: account) }

  # A minimal submission that acts as the CAF caf_submission.
  let(:submission) do
    create(:submission, template: template, created_by_user: user)
  end

  # UUIDs for two synthetic document attachments (no real blobs needed for
  # model-level tests — we reference them by UUID only).
  let(:caf_pdf_uuid)   { SecureRandom.uuid }
  let(:agreement_uuid) { SecureRandom.uuid }

  # CafStageDocument rows — the authoritative visibility registry.
  let!(:caf_doc) do
    CafStageDocument.create!(
      submission:    submission,
      document_uuid: caf_pdf_uuid,
      document_name: 'caf_summary.pdf',
      internal_only: true
    )
  end

  let!(:agreement_doc) do
    CafStageDocument.create!(
      submission:    submission,
      document_uuid: agreement_uuid,
      document_name: 'agreement.pdf',
      internal_only: false
    )
  end

  # Two submitters — one per stage.
  let(:stage1_submitter) do
    create(:submitter, submission: submission, account_id: account.id, uuid: SecureRandom.uuid)
  end

  let(:stage2_submitter) do
    create(:submitter, submission: submission, account_id: account.id, uuid: SecureRandom.uuid)
  end

  # Stage 1 — Internal IG Approval (position 0).
  let!(:stage1) do
    s = CafStage.create!(
      submission:               submission,
      name:                     'Internal CAF Approval',
      position:                 0,
      routing:                  'ordered',
      status:                   'active',
      activated_at:             1.minute.ago,
      strip_internal_on_complete: true
    )
    CafStageSubmitter.create!(caf_stage: s, submitter: stage1_submitter, role: 'BU Head', position: 0)
    s
  end

  # Stage 2 — Counterparty Signing (position 1).
  let!(:stage2) do
    s = CafStage.create!(
      submission:               submission,
      name:                     'Counterparty Signing',
      position:                 1,
      routing:                  'parallel',
      status:                   'pending',
      strip_internal_on_complete: false
    )
    CafStageSubmitter.create!(caf_stage: s, submitter: stage2_submitter,
                              role: 'Counterparty Signatory', position: 0)
    s
  end

  # Helper: build two fake ActiveStorage::Attachment stubs with the UUIDs above.
  # Used when we need an array that looks like schema_documents.
  def fake_attachments
    [
      instance_double(ActiveStorage::Attachment, uuid: caf_pdf_uuid),
      instance_double(ActiveStorage::Attachment, uuid: agreement_uuid)
    ]
  end

  # ── Submission#documents_for ─────────────────────────────────────────────────

  describe 'Submission#documents_for' do
    before do
      # Stub schema_documents to return our fake attachments so we don't need
      # real ActiveStorage blobs in a model spec.
      allow(submission).to receive(:schema_documents).and_return(fake_attachments)
    end

    context 'when submitter is in Stage 1 (position 0)' do
      it 'returns all documents (CAF PDF + agreement)' do
        docs = submission.documents_for(stage1_submitter)

        expect(docs.map(&:uuid)).to contain_exactly(caf_pdf_uuid, agreement_uuid)
      end
    end

    context 'when submitter is in Stage 2 (position 1)' do
      it 'returns only the agreement (internal_only: false)' do
        docs = submission.documents_for(stage2_submitter)

        expect(docs.map(&:uuid)).to contain_exactly(agreement_uuid)
      end

      it 'excludes the CAF summary PDF (internal_only: true)' do
        docs = submission.documents_for(stage2_submitter)

        expect(docs.map(&:uuid)).not_to include(caf_pdf_uuid)
      end
    end

    context 'when submitter has no associated CAF stage' do
      let(:unknown_submitter) do
        create(:submitter, submission: submission, account_id: account.id, uuid: SecureRandom.uuid)
      end

      it 'returns all documents (fail-safe: full visibility)' do
        docs = submission.documents_for(unknown_submitter)

        expect(docs.map(&:uuid)).to contain_exactly(caf_pdf_uuid, agreement_uuid)
      end
    end

    context 'when submission has no CAF stage documents at all' do
      let(:plain_submission) do
        create(:submission, template: template, created_by_user: user)
      end

      it 'delegates straight to schema_documents without filtering' do
        plain_submitter = create(:submitter, submission: plain_submission, account_id: account.id,
                                             uuid: SecureRandom.uuid)
        allow(plain_submission).to receive(:schema_documents).and_return(fake_attachments)

        docs = plain_submission.documents_for(plain_submitter)
        expect(docs.map(&:uuid)).to contain_exactly(caf_pdf_uuid, agreement_uuid)
      end
    end
  end

  # ── CafStage#complete! audit markers ────────────────────────────────────────

  describe 'CafStage#complete! audit markers' do
    it 'marks internal-only documents as stripped (informational audit flag)' do
      expect { stage1.complete! }
        .to change { caf_doc.reload.stripped }.from(false).to(true)
    end

    it 'records stripped_at timestamp' do
      freeze_time do
        stage1.complete!
        expect(caf_doc.reload.stripped_at).to be_within(1.second).of(Time.current)
      end
    end

    it 'does NOT mark the agreement as stripped' do
      stage1.complete!
      expect(agreement_doc.reload.stripped).to be(false)
    end

    it 'advances to Stage 2 after completion' do
      stage1.complete!
      expect(stage2.reload.status).to eq('active')
    end
  end

  # ── CafCompletionHandler — stage transition audit event ─────────────────────

  describe 'CafCompletionHandler stage transition audit event' do
    let(:caf_workflow) do
      create(:caf_workflow,
             account:          account,
             created_by_user:  user,
             caf_submission:   submission,
             status:           'pending_ig',
             counterparty_name:  'Test Party',
             counterparty_email: 'test@counterparty.com',
             entity:           'iti',
             caf_type:         'nda')
    end

    before do
      # Mark stage1 submitter complete so all_submitters_complete? returns true.
      stage1_submitter.update!(completed_at: Time.current)
    end

    it 'creates a stage_transition_to_counterparty SubmissionEvent' do
      expect do
        CafCompletionHandler.new(caf_workflow).call
      end.to change(SubmissionEvent, :count).by(1)

      event = SubmissionEvent.last
      expect(event.event_type).to eq('stage_transition_to_counterparty')
      expect(event.submission_id).to eq(submission.id)
    end

    it 'records visible and concealed document UUIDs in the event data' do
      CafCompletionHandler.new(caf_workflow).call

      # data is auto-deserialized via JSON (serialize :data, coder: JSON)
      data = SubmissionEvent.last.data
      expect(data['visible_document_uuids']).to contain_exactly(agreement_uuid)
      expect(data['concealed_document_uuids']).to contain_exactly(caf_pdf_uuid)
    end

    it 'updates workflow status to sent_counterparty' do
      CafCompletionHandler.new(caf_workflow).call
      expect(caf_workflow.reload.status).to eq('sent_counterparty')
    end
  end

  # ── Schema filtering helper (mirrors SubmitFormController behaviour) ─────────

  describe 'in-memory schema filtering for Stage 2 submitters' do
    # The schema contains one entry per document.
    let(:full_schema) do
      [
        { 'attachment_uuid' => caf_pdf_uuid,   'name' => 'caf-summary'  },
        { 'attachment_uuid' => agreement_uuid, 'name' => 'agreement'    }
      ]
    end

    before { submission.update!(template_schema: full_schema) }

    def filter_schema_for(submitter, sub)
      # Replicate the logic from SubmitFormController#maybe_filter_caf_schema_for_counterparty
      stage = CafStage.joins(:caf_stage_submitters)
                      .find_by(submission: sub,
                               caf_stage_submitters: { submitter_id: submitter.id })

      return unless stage&.position&.positive?

      internal_uuids = sub.caf_stage_documents.where(internal_only: true)
                          .pluck(:document_uuid).to_set

      sub.template_schema = (sub.template_schema.presence || sub.template&.schema || [])
                              .reject { |item| internal_uuids.include?(item['attachment_uuid']) }
    end

    context 'for a Stage 1 submitter' do
      it 'leaves template_schema unchanged' do
        filter_schema_for(stage1_submitter, submission)
        expect(submission.template_schema).to eq(full_schema)
      end
    end

    context 'for a Stage 2 submitter' do
      it 'removes internal-only entries from template_schema' do
        filter_schema_for(stage2_submitter, submission)
        uuids = submission.template_schema.map { |e| e['attachment_uuid'] }
        expect(uuids).to contain_exactly(agreement_uuid)
        expect(uuids).not_to include(caf_pdf_uuid)
      end

      it 'does not persist the change to the database' do
        filter_schema_for(stage2_submitter, submission)
        expect(submission.reload.template_schema).to eq(full_schema)
      end
    end
  end
end
