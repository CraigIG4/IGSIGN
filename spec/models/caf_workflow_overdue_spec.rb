# frozen_string_literal: true

require 'rails_helper'

RSpec.describe CafWorkflow, type: :model do
  let(:account) { create(:account) }
  let(:user)    { create(:user, account: account) }

  def build_workflow(status:, days_ago: 0)
    wf = build(:caf_workflow, account: account, created_by_user: user,
                              status: status)
    wf.save(validate: false)
    wf.update_columns(status_updated_at: days_ago.days.ago)
    wf
  end

  describe '#days_in_current_stage' do
    it 'returns 0 for a workflow updated today' do
      wf = build_workflow(status: 'pending_ig', days_ago: 0)
      expect(wf.days_in_current_stage).to eq(0)
    end

    it 'returns approximate days based on status_updated_at' do
      wf = build_workflow(status: 'pending_ig', days_ago: 6)
      expect(wf.days_in_current_stage).to be_between(5, 7)
    end
  end

  describe '#overdue?' do
    it 'is false for a workflow in current stage < 10 days' do
      wf = build_workflow(status: 'pending_ig', days_ago: 9)
      expect(wf.overdue?).to be false
    end

    it 'is true for a workflow in current stage > 9 days' do
      wf = build_workflow(status: 'pending_ig', days_ago: 10)
      expect(wf.overdue?).to be true
    end

    it 'is false for complete workflows regardless of time' do
      wf = build_workflow(status: 'complete', days_ago: 30)
      expect(wf.overdue?).to be false
    end

    it 'is false for draft workflows' do
      wf = build_workflow(status: 'draft', days_ago: 15)
      expect(wf.overdue?).to be false
    end

    it 'is true for sent_counterparty overdue' do
      wf = build_workflow(status: 'sent_counterparty', days_ago: 12)
      expect(wf.overdue?).to be true
    end
  end

  describe '#slightly_overdue?' do
    it 'is true between 5 and 9 days' do
      wf = build_workflow(status: 'pending_ig', days_ago: 6)
      expect(wf.slightly_overdue?).to be true
    end

    it 'is false at exactly 5 days (threshold is >5)' do
      wf = build_workflow(status: 'pending_ig', days_ago: 5)
      # days_in_current_stage rounds down, so 5 days ago = 5 days = not > 5
      expect(wf.slightly_overdue?).to be false
    end
  end

  describe '.overdue scope' do
    it 'returns only active-status workflows that are > 9 days old' do
      old_pending  = build_workflow(status: 'pending_ig',   days_ago: 10)
      new_pending  = build_workflow(status: 'pending_ig',   days_ago: 2)
      complete_old = build_workflow(status: 'complete',     days_ago: 15)
      old_cp       = build_workflow(status: 'sent_counterparty', days_ago: 11)

      overdue = CafWorkflow.overdue
      expect(overdue).to include(old_pending, old_cp)
      expect(overdue).not_to include(new_pending, complete_old)
    end
  end

  describe '#current_holder_name' do
    context 'when sent_counterparty' do
      it 'returns counterparty_name when present' do
        wf = build_workflow(status: 'sent_counterparty', days_ago: 1)
        wf.update_columns(counterparty_name: 'Alice External')
        expect(wf.current_holder_name).to eq('Alice External')
      end

      it 'falls back to contracting_party' do
        wf = build_workflow(status: 'sent_counterparty', days_ago: 1)
        wf.update_columns(counterparty_name: '', contracting_party: 'Acme Corp')
        expect(wf.current_holder_name).to eq('Acme Corp')
      end
    end

    context 'when draft' do
      it 'returns nil' do
        wf = build_workflow(status: 'draft', days_ago: 0)
        expect(wf.current_holder_name).to be_nil
      end
    end
  end
end
