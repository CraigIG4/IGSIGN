# frozen_string_literal: true

# Tests for the Step 2b field-placement helpers and the field-merge step in
# CafSubmissionCreator:
#
#   AgreementsController (private helpers)
#     #sync_template_submitters!  — copies CAF Template UUIDs to agreement template
#     #auto_place_fields!         — populates default sig/name/date grid
#     #build_auto_fields          — one party's three fields
#     #field_coverage_errors      — lists parties missing a signature field
#
#   CafSubmissionCreator
#     #attach_contract_document   — reads blob from @caf.template, not contract_document
#     #merge_agreement_template_fields! — remaps att UUID and merges into submission
#
require 'rails_helper'

RSpec.describe 'CAF field placement', type: :model do
  # ── Shared fixtures ──────────────────────────────────────────────────────────

  let(:user)    { create(:user) }
  let(:account) { user.account }

  # CAF template with two submitters (simplified: BU Head + Counterparty)
  let(:caf_template) do
    create(:template, account: account, author: user,
                      name: 'IGSIGN CAF Template',
                      submitter_count: 0, attachment_count: 0,
                      submitters: [
                        { 'name' => 'BU Head',      'uuid' => bu_head_uuid },
                        { 'name' => 'Counterparty', 'uuid' => cp_uuid }
                      ],
                      fields: [])
  end

  let(:bu_head_uuid) { SecureRandom.uuid }
  let(:cp_uuid)      { SecureRandom.uuid }

  # Agreement template (uploaded doc)
  let(:att_uuid)          { SecureRandom.uuid }
  let(:agreement_template) do
    t = create(:template, account: account, author: user,
                          name: 'MSA — ACME',
                          submitter_count: 0, attachment_count: 0,
                          submitters: [],
                          fields: [],
                          schema: [{ 'attachment_uuid' => att_uuid, 'name' => 'agreement' }])
    # Pretend schema_documents.first returns something with .uuid
    allow(t).to receive_message_chain(:schema_documents, :first).and_return(
      instance_double(ActiveStorage::Attachment, uuid: att_uuid)
    )
    t
  end

  let(:agreement) do
    create(:caf_workflow,
           account:          account,
           created_by_user:  user,
           entity:           'iti',
           agreement_type:   'msa',
           template_id:      agreement_template.id,
           signatories: [
             { 'role' => 'BU Head',      'name' => 'Jane Doe',  'email' => 'jane@ig.com',
               'position' => 0, 'placeholder' => false },
             { 'role' => 'Counterparty', 'name' => 'Bob Smith', 'email' => 'bob@acme.com',
               'position' => 1, 'placeholder' => false }
           ])
  end

  # Controller helpers are private — exercise them through a thin test harness.
  let(:controller) do
    ctrl = AgreementsController.new
    ctrl.instance_variable_set(:@agreement, agreement)
    ctrl
  end

  # ── sync_template_submitters! ────────────────────────────────────────────────

  describe '#sync_template_submitters!' do
    before { caf_template } # ensure it exists in the DB

    it 'copies the BU Head UUID from the CAF template to the agreement template' do
      controller.send(:sync_template_submitters!)
      subs = agreement_template.reload.submitters
      bu = subs.find { |s| s['name'] == 'BU Head' }
      expect(bu['uuid']).to eq(bu_head_uuid)
    end

    it 'always includes the Counterparty submitter' do
      controller.send(:sync_template_submitters!)
      names = agreement_template.reload.submitters.map { |s| s['name'] }
      expect(names).to include('Counterparty')
    end

    it 'assigns the Counterparty UUID from the CAF template' do
      controller.send(:sync_template_submitters!)
      subs = agreement_template.reload.submitters
      cp = subs.find { |s| s['name'] == 'Counterparty' }
      expect(cp['uuid']).to eq(cp_uuid)
    end

    it 'is idempotent — calling twice does not double-append submitters' do
      controller.send(:sync_template_submitters!)
      controller.send(:sync_template_submitters!)
      expect(agreement_template.reload.submitters.length).to eq(2)
    end

    it 'is a no-op when the IGSIGN CAF Template does not exist' do
      # No caf_template record in DB this time
      caf_template.destroy
      expect { controller.send(:sync_template_submitters!) }.not_to raise_error
      expect(agreement_template.reload.submitters).to be_blank
    end
  end

  # ── build_auto_fields ────────────────────────────────────────────────────────

  describe '#build_auto_fields' do
    let(:fields) { controller.send(:build_auto_fields, bu_head_uuid, 'BU Head', att_uuid, 0) }

    it 'returns three fields' do
      expect(fields.length).to eq(3)
    end

    it 'sets types to signature, text, date' do
      expect(fields.map { |f| f['type'] }).to eq(%w[signature text date])
    end

    it 'binds all fields to the given submitter UUID' do
      expect(fields.map { |f| f['submitter_uuid'] }.uniq).to eq([bu_head_uuid])
    end

    it 'references the correct attachment UUID in every area' do
      uuids = fields.flat_map { |f| f['areas'].map { |a| a['attachment_uuid'] } }.uniq
      expect(uuids).to eq([att_uuid])
    end

    it 'positions the second party below the first (y offset by 0.07)' do
      first_party  = controller.send(:build_auto_fields, bu_head_uuid, 'BU Head', att_uuid, 0)
      second_party = controller.send(:build_auto_fields, cp_uuid, 'Counterparty', att_uuid, 1)

      first_y  = first_party.first['areas'].first['y']
      second_y = second_party.first['areas'].first['y']
      expect(second_y - first_y).to be_within(0.001).of(0.07)
    end
  end

  # ── auto_place_fields! ───────────────────────────────────────────────────────

  describe '#auto_place_fields!' do
    before do
      caf_template
      allow(agreement).to receive(:template).and_return(agreement_template)
      controller.send(:sync_template_submitters!)
    end

    it 'populates fields on the agreement template' do
      controller.send(:auto_place_fields!)
      expect(agreement_template.reload.fields).not_to be_empty
    end

    it 'creates 3 fields per submitter (sig + name + date)' do
      controller.send(:auto_place_fields!)
      expect(agreement_template.reload.fields.length).to eq(6) # 2 parties × 3 fields
    end

    it 'does not overwrite existing fields' do
      existing = [{ 'uuid' => SecureRandom.uuid, 'type' => 'signature',
                    'submitter_uuid' => bu_head_uuid, 'areas' => [] }]
      agreement_template.update!(fields: existing)
      controller.send(:auto_place_fields!)
      expect(agreement_template.reload.fields).to eq(existing)
    end
  end

  # ── field_coverage_errors ────────────────────────────────────────────────────

  describe '#field_coverage_errors' do
    context 'when every submitter has a signature field' do
      before do
        agreement_template.update!(
          submitters: [
            { 'name' => 'BU Head',      'uuid' => bu_head_uuid },
            { 'name' => 'Counterparty', 'uuid' => cp_uuid }
          ],
          fields: [
            { 'type' => 'signature', 'submitter_uuid' => bu_head_uuid, 'areas' => [] },
            { 'type' => 'signature', 'submitter_uuid' => cp_uuid,      'areas' => [] }
          ]
        )
      end

      it 'returns an empty array' do
        errors = controller.send(:field_coverage_errors, agreement_template.reload)
        expect(errors).to be_empty
      end
    end

    context 'when a submitter has no signature field' do
      before do
        agreement_template.update!(
          submitters: [
            { 'name' => 'BU Head',      'uuid' => bu_head_uuid },
            { 'name' => 'Counterparty', 'uuid' => cp_uuid }
          ],
          fields: [
            { 'type' => 'text', 'submitter_uuid' => bu_head_uuid, 'areas' => [] }
            # Counterparty has no fields at all
          ]
        )
      end

      it 'returns the names of uncovered parties' do
        errors = controller.send(:field_coverage_errors, agreement_template.reload)
        expect(errors).to contain_exactly('BU Head', 'Counterparty')
      end
    end

    context 'when there are no submitters' do
      before { agreement_template.update!(submitters: [], fields: []) }

      it 'returns an empty array' do
        expect(controller.send(:field_coverage_errors, agreement_template.reload)).to be_empty
      end
    end
  end

  # ── CafSubmissionCreator — attach_contract_document ──────────────────────────

  describe 'CafSubmissionCreator#attach_contract_document' do
    let(:template)   { create(:template, author: user, account: account) }
    let(:submission) { create(:submission, template: template, created_by_user: user) }
    let(:creator)    { CafSubmissionCreator.new(agreement, user) }

    context 'when @caf.template has no documents attached' do
      before { allow(agreement).to receive(:template).and_return(nil) }

      it 'returns without raising' do
        expect { creator.send(:attach_contract_document, submission) }.not_to raise_error
      end
    end

    context 'when @caf has no template_id' do
      before { agreement.update!(template_id: nil) }

      it 'returns without raising' do
        expect { creator.send(:attach_contract_document, submission) }.not_to raise_error
      end
    end
  end

  # ── CafSubmissionCreator — merge_agreement_template_fields! ──────────────────

  describe 'CafSubmissionCreator#merge_agreement_template_fields!' do
    let(:base_template) { create(:template, author: user, account: account) }
    let(:submission)    { create(:submission, template: base_template, created_by_user: user) }
    let(:creator)       { CafSubmissionCreator.new(agreement, user) }

    context 'when the agreement template has no fields' do
      before { agreement_template.update!(fields: []) }

      it 'does not set template_fields on the submission' do
        creator.send(:merge_agreement_template_fields!, submission)
        expect(submission.reload.template_fields).to be_blank
      end
    end

    context 'when the agreement template has fields but no attachment in submission' do
      before do
        agreement_template.update!(
          fields: [{ 'uuid' => SecureRandom.uuid, 'type' => 'signature',
                     'submitter_uuid' => bu_head_uuid,
                     'areas' => [{ 'attachment_uuid' => att_uuid }] }]
        )
        # No blob attached to the submission
        src_attach = instance_double(ActiveStorage::Attachment, uuid: att_uuid, blob_id: 999)
        allow(agreement.template).to receive_message_chain(:documents, :attachments)
          .and_return([src_attach])
      end

      it 'does not raise' do
        expect { creator.send(:merge_agreement_template_fields!, submission) }.not_to raise_error
      end

      it 'leaves template_fields blank' do
        creator.send(:merge_agreement_template_fields!, submission)
        expect(submission.reload.template_fields).to be_blank
      end
    end
  end
end
