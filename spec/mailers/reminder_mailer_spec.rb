# frozen_string_literal: true

require 'rails_helper'

RSpec.describe ReminderMailer, type: :mailer do
  let(:account)    { create(:account) }
  let(:user)       { create(:user, account: account) }
  let(:template)   { create(:template, account: account, author: user) }
  let(:workflow) do
    create(:caf_workflow,
           account:            account,
           created_by_user:    user,
           requestor_name:     'Test Requestor',
           requestor_email:    'requestor@example.com',
           contracting_party:  'Acme Corp',
           agreement_type:     'msa')
  end
  let(:submission) { create(:submission, template: template, created_by_user: user) }
  let(:stage)      { create(:caf_stage, submission: submission, status: 'active') }
  let(:submitter) do
    create(:submitter, submission: submission,
                       name: 'Alice Smith', email: 'alice@example.com')
  end
  let(:css) do
    create(:caf_stage_submitter,
           caf_stage: stage, submitter: submitter,
           role: 'CLO', invited_at: 5.days.ago)
  end

  before do
    # Wire caf_workflow lookup: CafWorkflow.find_by(caf_submission_id: submission.id)
    allow(CafWorkflow).to receive(:find_by)
      .with(caf_submission_id: submission.id)
      .and_return(workflow)
  end

  describe '#signing_reminder' do
    subject(:mail) { described_class.signing_reminder(css, 5) }

    it 'delivers to the submitter' do
      expect(mail.to).to eq(['alice@example.com'])
    end

    it 'includes the counterparty in the subject' do
      expect(mail.subject).to match(/Acme Corp/)
    end

    it 'shows "Action Required" urgency for day 5' do
      expect(mail.subject).to match(/Action Required/i)
    end

    it 'renders the body without errors' do
      expect { mail.body }.not_to raise_error
    end
  end

  describe '#signing_reminder — day 9 subject' do
    subject(:mail) { described_class.signing_reminder(css, 9) }

    it 'shows "Urgent" in subject for day 9' do
      expect(mail.subject).to match(/Urgent/i)
    end
  end

  describe '#escalation_notice' do
    subject(:mail) { described_class.escalation_notice(css) }

    it 'delivers to the requestor not the submitter' do
      expect(mail.to).to eq(['requestor@example.com'])
    end

    it 'contains the blocked submitter name in the body' do
      expect(mail.body.encoded).to include('Alice Smith')
    end

    it 'renders the body without errors' do
      expect { mail.body }.not_to raise_error
    end

    context 'when caf_workflow is nil' do
      before do
        allow(CafWorkflow).to receive(:find_by)
          .with(caf_submission_id: submission.id)
          .and_return(nil)
      end

      it 'does not raise' do
        expect { described_class.escalation_notice(css) }.not_to raise_error
      end
    end
  end
end
