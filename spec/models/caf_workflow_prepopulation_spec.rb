# frozen_string_literal: true

# Comprehensive spec for IgSignatories.chain_for and CafWorkflow#auto_assign_signatories!
#
# Tests every (entity × caf_type) combination. We test:
#   1. chain_for directly (pure Ruby, no DB)
#   2. auto_assign_signatories! on a built CafWorkflow (exercises the mapping layer)

require 'rails_helper'

RSpec.describe 'IG Signer Prepopulation', :aggregate_failures do
  # ── Helpers ──────────────────────────────────────────────────────────────────

  def email(key)
    IgSignatories::PEOPLE.fetch(key).fetch(:email)
  end

  # ── Part 1: IgSignatories.chain_for (unit tests, no DB) ─────────────────────

  describe IgSignatories, '.chain_for' do
    it 'returns a hash with :stage1 and :stage2 keys' do
      result = IgSignatories.chain_for('nda', :iti)
      expect(result).to have_key(:stage1)
      expect(result).to have_key(:stage2)
      expect(result[:stage2]).to eq([])
    end

    it 'returns empty stage1 for an unknown entity' do
      expect(IgSignatories.chain_for('nda', :unknown_entity)[:stage1]).to eq([])
    end

    it 'each entry has :key, :name, :title, :email' do
      entry = IgSignatories.chain_for('nda', :iti)[:stage1].first
      expect(entry).to include(:key, :name, :title, :email)
    end

    it 'accepts string or symbol caf_type' do
      sym_result    = IgSignatories.chain_for(:nda,   :iti)[:stage1]
      string_result = IgSignatories.chain_for('nda',  :iti)[:stage1]
      expect(sym_result).to eq(string_result)
    end

    it 'accepts string or symbol entity_key' do
      sym_result    = IgSignatories.chain_for('nda', :iti)[:stage1]
      string_result = IgSignatories.chain_for('nda', 'iti')[:stage1]
      expect(sym_result).to eq(string_result)
    end

    # ── NDA: first BU head + finance + CEO ──

    context 'nda chains' do
      it 'iti: william_talbot, laren_farquharson, sean_bergsma' do
        chain = IgSignatories.chain_for('nda', :iti)[:stage1]
        expect(chain.map { |e| e[:email] }).to eq([
          email(:william_talbot),
          email(:laren_farquharson),
          email(:sean_bergsma)
        ])
      end

      it 'comit: william_talbot, laren_farquharson, sean_bergsma' do
        chain = IgSignatories.chain_for('nda', :comit)[:stage1]
        expect(chain.map { |e| e[:email] }).to eq([
          email(:william_talbot),
          email(:laren_farquharson),
          email(:sean_bergsma)
        ])
      end

      it 'ccs: craig_daroche (first bu_head), laren_farquharson, sean_bergsma' do
        chain = IgSignatories.chain_for('nda', :ccs)[:stage1]
        expect(chain.map { |e| e[:email] }).to eq([
          email(:craig_daroche),
          email(:laren_farquharson),
          email(:sean_bergsma)
        ])
      end

      it 'mvnx: ashley_fourie, laren_farquharson, sean_bergsma' do
        chain = IgSignatories.chain_for('nda', :mvnx)[:stage1]
        expect(chain.map { |e| e[:email] }).to eq([
          email(:ashley_fourie),
          email(:laren_farquharson),
          email(:sean_bergsma)
        ])
      end
    end

    # ── Short form: first BU head + finance + COO ──

    context 'short_form chains' do
      it 'iti: william_talbot, laren_farquharson, donovan_bergsma' do
        chain = IgSignatories.chain_for('short_form', :iti)[:stage1]
        expect(chain.map { |e| e[:email] }).to eq([
          email(:william_talbot),
          email(:laren_farquharson),
          email(:donovan_bergsma)
        ])
      end

      it 'ignite_training: craig_daroche, laren_farquharson, donovan_bergsma' do
        chain = IgSignatories.chain_for('short_form', :ignite_training)[:stage1]
        expect(chain.map { |e| e[:email] }).to eq([
          email(:craig_daroche),
          email(:laren_farquharson),
          email(:donovan_bergsma)
        ])
      end

      it 'chase_tracking: william_talbot, laren_farquharson, donovan_bergsma' do
        chain = IgSignatories.chain_for('short_form', :chase_tracking)[:stage1]
        expect(chain.map { |e| e[:email] }).to eq([
          email(:william_talbot),
          email(:laren_farquharson),
          email(:donovan_bergsma)
        ])
      end
    end

    # ── Long form: all BU heads + finance + CEO ──

    context 'long_form chains' do
      it 'iti: all 3 BU heads + finance + CEO = 5 signatories' do
        chain = IgSignatories.chain_for('long_form', :iti)[:stage1]
        expect(chain.length).to eq(5)
        expect(chain.map { |e| e[:email] }).to eq([
          email(:william_talbot),
          email(:craig_daroche),
          email(:richard_swart),
          email(:laren_farquharson),
          email(:sean_bergsma)
        ])
      end

      it 'comit: 2 BU heads + finance + CEO = 4 signatories' do
        chain = IgSignatories.chain_for('long_form', :comit)[:stage1]
        expect(chain.length).to eq(4)
        expect(chain.map { |e| e[:email] }).to eq([
          email(:william_talbot),
          email(:craig_daroche),
          email(:laren_farquharson),
          email(:sean_bergsma)
        ])
      end

      it 'ccs: craig_daroche, richard_swart, laren_farquharson, sean_bergsma' do
        chain = IgSignatories.chain_for('long_form', :ccs)[:stage1]
        expect(chain.map { |e| e[:email] }).to eq([
          email(:craig_daroche),
          email(:richard_swart),
          email(:laren_farquharson),
          email(:sean_bergsma)
        ])
      end

      it 'mvnx: sole BU head — same length as nda chain (3)' do
        nda       = IgSignatories.chain_for('nda', :mvnx)[:stage1]
        long_form = IgSignatories.chain_for('long_form', :mvnx)[:stage1]
        expect(long_form.length).to eq(nda.length)
      end

      it 'no duplicate signatories in any chain' do
        IgSignatories::ENTITIES.each_key do |ek|
          chain  = IgSignatories.chain_for('long_form', ek)[:stage1]
          emails = chain.map { |e| e[:email] }
          expect(emails.uniq).to eq(emails), "Duplicate signatories in #{ek}/long_form"
        end
      end
    end

    # ── Exhaustive coverage: all 13 entities × 3 types ──

    context 'all 13 entities × 3 caf_types' do
      IgSignatories::ENTITIES.each_key do |entity_key|
        %w[nda short_form long_form].each do |caf_type|
          context "#{entity_key} / #{caf_type}" do
            let(:chain) { IgSignatories.chain_for(caf_type, entity_key)[:stage1] }

            it 'has at least 2 signatories' do
              expect(chain.length).to be >= 2
            end

            it 'all entries have name, title, email' do
              chain.each_with_index do |entry, i|
                expect(entry[:name]).to  be_present, "Entry #{i} missing :name"
                expect(entry[:title]).to be_present, "Entry #{i} missing :title"
                expect(entry[:email]).to be_present, "Entry #{i} missing :email"
              end
            end

            it 'all emails are @ignitiongroup.co.za' do
              chain.each do |entry|
                expect(entry[:email]).to end_with('@ignitiongroup.co.za')
              end
            end
          end
        end
      end
    end

    # ── Active/inactive filtering ──

    context 'active/inactive filtering' do
      let(:overrides) { { 'william_talbot' => { 'active' => false } } }

      before { allow(IgSignatories).to receive(:overrides).and_return(overrides) }

      it 'excludes an inactive primary BU head from NDA chain for iti' do
        chain  = IgSignatories.chain_for('nda', :iti)[:stage1]
        emails = chain.map { |e| e[:email] }
        expect(emails).not_to include(email(:william_talbot))
      end

      it 'promotes next BU head when primary is inactive (NDA: first only)' do
        chain = IgSignatories.chain_for('nda', :iti)[:stage1]
        expect(chain.first[:email]).to eq(email(:craig_daroche))
      end

      it 'still includes finance and CEO after deactivation' do
        chain  = IgSignatories.chain_for('nda', :iti)[:stage1]
        emails = chain.map { |e| e[:email] }
        expect(emails).to include(email(:laren_farquharson), email(:sean_bergsma))
      end

      it 'excludes inactive person from long_form multi-head chain' do
        chain  = IgSignatories.chain_for('long_form', :iti)[:stage1]
        emails = chain.map { |e| e[:email] }
        expect(emails).not_to include(email(:william_talbot))
        expect(emails).to include(email(:craig_daroche), email(:richard_swart))
      end

      it 'still returns finance + CEO when sole BU head is inactive' do
        allow(IgSignatories).to receive(:overrides).and_return('ashley_fourie' => { 'active' => false })
        chain  = IgSignatories.chain_for('nda', :mvnx)[:stage1]
        emails = chain.map { |e| e[:email] }
        expect(emails).not_to include(email(:ashley_fourie))
        expect(emails).to include(email(:laren_farquharson), email(:sean_bergsma))
      end
    end
  end

  # ── Part 2: CafWorkflow#auto_assign_signatories! ─────────────────────────────

  describe CafWorkflow, '#auto_assign_signatories!', type: :model do
    let(:account) { create(:account) }
    let(:user)    { create(:user, account:) }

    def workflow_for(entity:, agreement_type:)
      build(:caf_workflow, entity: entity.to_s, agreement_type:, account:, created_by_user: user)
    end

    context 'field mapping' do
      it 'role is populated from :title (not nil)' do
        wf = workflow_for(entity: :iti, agreement_type: 'nda')
        wf.auto_assign_signatories!
        expect(wf.signatories.first['role']).to eq('BU Head - Technology')
      end

      it 'every signatory has name, email, role, position, key, placeholder' do
        wf = workflow_for(entity: :iti, agreement_type: 'msa')
        wf.auto_assign_signatories!
        wf.signatories.each_with_index do |s, idx|
          expect(s['name']).to         be_present, "Signatory #{idx} missing name"
          expect(s['email']).to        be_present, "Signatory #{idx} missing email"
          expect(s['role']).to         be_present, "Signatory #{idx} missing role"
          expect(s['position']).to     eq(idx)
          expect(s['key']).to          be_present, "Signatory #{idx} missing key"
          expect(s['placeholder']).to  eq(false)
        end
      end

      it 'positions are sequential 0-based integers' do
        wf = workflow_for(entity: :iti, agreement_type: 'msa')
        wf.auto_assign_signatories!
        positions = wf.signatories.map { |s| s['position'] }
        expect(positions).to eq((0...wf.signatories.length).to_a)
      end
    end

    context 'NDA (agreement_type: nda)' do
      it 'iti: 3 signatories, first is William Talbot, last is Sean Bergsma' do
        wf = workflow_for(entity: :iti, agreement_type: 'nda')
        wf.auto_assign_signatories!
        expect(wf.signatories.length).to  eq(3)
        expect(wf.signatories.first['email']).to eq(email(:william_talbot))
        expect(wf.signatories.last['email']).to  eq(email(:sean_bergsma))
      end

      it 'ccs: first signatory is Craig Daroche' do
        wf = workflow_for(entity: :ccs, agreement_type: 'nda')
        wf.auto_assign_signatories!
        expect(wf.signatories.first['email']).to eq(email(:craig_daroche))
      end
    end

    context 'Short form (agreement_type: addendum)' do
      it 'iti: 3 signatories, last is Donovan Bergsma (COO)' do
        wf = workflow_for(entity: :iti, agreement_type: 'addendum')
        wf.auto_assign_signatories!
        expect(wf.signatories.length).to eq(3)
        expect(wf.signatories.last['email']).to eq(email(:donovan_bergsma))
      end

      it 'all entities: last signatory is always Donovan Bergsma' do
        IgSignatories::ENTITIES.each_key do |ek|
          wf = workflow_for(entity: ek, agreement_type: 'addendum')
          wf.auto_assign_signatories!
          expect(wf.signatories.last['email']).to eq(email(:donovan_bergsma)),
            "Expected Donovan Bergsma last for #{ek}/short_form"
        end
      end
    end

    context 'Long form (agreement_type: msa)' do
      it 'iti: 5 signatories (3 BU heads + finance + CEO)' do
        wf = workflow_for(entity: :iti, agreement_type: 'msa')
        wf.auto_assign_signatories!
        expect(wf.signatories.length).to eq(5)
      end

      it 'all entities: last signatory is always Sean Bergsma (CEO)' do
        IgSignatories::ENTITIES.each_key do |ek|
          wf = workflow_for(entity: ek, agreement_type: 'msa')
          wf.auto_assign_signatories!
          expect(wf.signatories.last['email']).to eq(email(:sean_bergsma)),
            "Expected Sean Bergsma last for #{ek}/long_form"
        end
      end

      it 'all entities: second-to-last is always Laren Farquharson (Finance)' do
        IgSignatories::ENTITIES.each_key do |ek|
          wf = workflow_for(entity: ek, agreement_type: 'msa')
          wf.auto_assign_signatories!
          expect(wf.signatories[-2]['email']).to eq(email(:laren_farquharson)),
            "Expected Laren Farquharson second-to-last for #{ek}/long_form"
        end
      end
    end

    context 'agreement_type to caf_type mapping' do
      {
        'nda'        => :sean_bergsma,      # nda → CEO
        'msa'        => :sean_bergsma,      # long_form → CEO
        'sla'        => :sean_bergsma,      # long_form → CEO
        'vendor'     => :sean_bergsma,      # long_form → CEO
        'other'      => :sean_bergsma,      # long_form → CEO
        'policy'     => :sean_bergsma,      # nda → CEO
        'addendum'   => :donovan_bergsma,   # short_form → COO
        'employment' => :donovan_bergsma    # short_form → COO
      }.each do |agreement_type, expected_last_person|
        it "#{agreement_type} → last signer is #{expected_last_person}" do
          wf = workflow_for(entity: :iti, agreement_type:)
          wf.auto_assign_signatories!
          expect(wf.signatories.last['email']).to eq(email(expected_last_person))
        end
      end
    end
  end

  # ── Part 3: IgSignatories helper methods ─────────────────────────────────────

  describe IgSignatories, 'helper methods' do
    describe '.entity_name' do
      it 'returns full legal name for a known entity key' do
        expect(IgSignatories.entity_name(:iti)).to eq('Ignition Telecoms Investments (Pty) Ltd')
      end

      it 'accepts string keys' do
        expect(IgSignatories.entity_name('comit')).to eq('Comit Technologies (Pty) Ltd')
      end

      it 'returns nil for unknown entity' do
        expect(IgSignatories.entity_name(:nonexistent)).to be_nil
      end
    end

    describe '.person_active?' do
      it 'returns true for all people with empty overrides' do
        IgSignatories::PEOPLE.each_key do |key|
          expect(IgSignatories.person_active?(key, {})).to be(true), "Expected #{key} to be active"
        end
      end

      it 'returns false when override sets active: false' do
        overrides = { 'william_talbot' => { 'active' => false } }
        expect(IgSignatories.person_active?(:william_talbot, overrides)).to be(false)
      end

      it 'returns true when override explicitly sets active: true' do
        overrides = { 'william_talbot' => { 'active' => true } }
        expect(IgSignatories.person_active?(:william_talbot, overrides)).to be(true)
      end
    end

    describe '.entities_for_js' do
      it 'returns an array with all 13 entities' do
        expect(IgSignatories.entities_for_js.length).to eq(13)
      end

      it 'each entry has key, name, short_name, registration, address' do
        IgSignatories.entities_for_js.each do |e|
          expect(e[:key]).to          be_present
          expect(e[:name]).to         be_present
          expect(e[:short_name]).to   be_present
          expect(e[:registration]).to be_present
          expect(e[:address]).to      be_present
        end
      end
    end
  end
end
