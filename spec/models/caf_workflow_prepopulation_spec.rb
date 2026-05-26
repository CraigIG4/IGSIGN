# frozen_string_literal: true

# Spec for IgSignatories.chain_for and CafWorkflow#auto_assign_signatories!
#
# All data is now database-backed.  The seed file is loaded once for the suite.
# Tests use the canonical signatory data from db/seeds/igsign_registry.rb.

require 'rails_helper'

RSpec.describe 'IG Signer Prepopulation', :aggregate_failures do # rubocop:disable RSpec/DescribeClass
  # Load the canonical registry once for this spec file.
  # The seed is idempotent so this is safe to run in a test transaction.
  before(:all) do
    load Rails.root.join('db/seeds/igsign_registry.rb')
  end

  # ── Canonical email helpers ────────────────────────────────────────────────

  CANONICAL_EMAILS = {
    sean_bergsma:      'Sean.Bergsma@ignitiongroup.co.za',
    donovan_bergsma:   'Donovan.Bergsma@ignitiongroup.co.za',
    craig_lawrence:    'Clawre969@ignitiongroup.co.za',
    laren_farquharson: 'Laren.Farquharson@ignitiongroup.co.za',
    callie_baney:      'Callie.Baney@ignitiongroup.co.za',
    william_talbot:    'William.Talbot@ignitiongroup.co.za',
    mark_mitchell:     'Mark.Mitchell@ignitioncx.com',
    daniel_swart:      'Daniel.Swart@mvnxmobile.co.za',
    matthew_van_as:    'Matthew.VanAs@mvnxmobile.co.za',
    ivor_vonnielen:    'ivor.vonnielen@uconnect.co.za',
    nikola_ramsden:    'Nikola.Ramsden@spot.co.za',
    siddeek_rahim:     'siddeek.rahim@uconnect.co.za',
    verona_naidoo:     'Verona.Naidoo@ignitiongroup.co.za',
    daniel_schauffer:  'Daniel.Schauffer@ignitiongroup.co.za',
    kobus_botha:       'kobus.botha@igfs.co.za',
    angeline_bennett:  'angeline.bennett@igfs.co.za',
    pedro_casimiro:    'Pedro.Casimiro@ignitiongroup.co.za',
    allan_randell:     'Allan.Randell@spot.co.za'
  }.freeze

  def email(key)
    CANONICAL_EMAILS.fetch(key) { raise "Unknown canonical key: #{key}" }
  end

  # ── Part 1: IgSignatories.chain_for ───────────────────────────────────────

  describe IgSignatories, '.chain_for' do
    it 'returns a hash with :stage1 and :stage2 keys' do
      result = IgSignatories.chain_for(:iti, 'nda')
      expect(result).to have_key(:stage1)
      expect(result).to have_key(:stage2)
      expect(result[:stage2]).to eq([])
    end

    it 'returns empty stage1 for an unknown entity' do
      expect(IgSignatories.chain_for(:unknown_entity, 'nda')[:stage1]).to eq([])
    end

    it 'each entry has :name, :title, :email, :position' do
      entry = IgSignatories.chain_for(:iti, 'msa')[:stage1].first
      expect(entry).to include(:name, :title, :email, :position)
    end

    it 'accepts string or symbol agreement_type' do
      sym_result    = IgSignatories.chain_for(:iti, :msa)[:stage1]
      string_result = IgSignatories.chain_for(:iti, 'msa')[:stage1]
      expect(sym_result).to eq(string_result)
    end

    it 'accepts string or symbol entity_key' do
      sym_result    = IgSignatories.chain_for(:iti,  'msa')[:stage1]
      string_result = IgSignatories.chain_for('iti', 'msa')[:stage1]
      expect(sym_result).to eq(string_result)
    end

    # ── NDA chains: Craig Lawrence alone ──────────────────────────────────────

    context 'NDA agreement type' do
      it 'ITI: Craig Lawrence only' do
        chain = IgSignatories.chain_for(:iti, 'nda')[:stage1]
        expect(chain.map { |e| e[:email] }).to eq([email(:craig_lawrence)])
      end

      it 'Comit: Craig Lawrence only' do
        chain = IgSignatories.chain_for(:comit, 'nda')[:stage1]
        expect(chain.map { |e| e[:email] }).to eq([email(:craig_lawrence)])
      end

      it 'all entities return exactly Craig Lawrence for NDA' do
        IgEntity.active.pluck(:key).each do |ek|
          chain = IgSignatories.chain_for(ek, 'nda')[:stage1]
          expect(chain.map { |e| e[:email] }).to eq([email(:craig_lawrence)]),
            "Expected Craig Lawrence only for #{ek}/nda"
        end
      end
    end

    # ── Non-NDA: BU Head + BU CFO + Group CLO + Group CFO + Group Signer ──────

    context 'MSA agreement type (non-NDA)' do
      it 'ITI: includes William Talbot (bu_head), Laren (bu_cfo+group_cfo), Craig L (group_clo), Sean (group_signer)' do
        chain  = IgSignatories.chain_for(:iti, 'msa')[:stage1]
        emails = chain.map { |e| e[:email] }
        expect(emails).to include(
          email(:william_talbot),
          email(:laren_farquharson),
          email(:craig_lawrence),
          email(:sean_bergsma)
        )
      end

      it 'Spot Connect Stage 1 includes Siddeek (group_signer) and Sean (group_signer_alt)' do
        chain  = IgSignatories.chain_for(:spot_connect, 'msa')[:stage1]
        emails = chain.map { |e| e[:email] }
        expect(emails).to include(email(:siddeek_rahim), email(:sean_bergsma))
      end

      it 'IFS: includes Kobus Botha as both bu_head and group_signer; Sean as approver_only' do
        chain     = IgSignatories.chain_for(:ifs, 'msa')[:stage1]
        emails    = chain.map { |e| e[:email] }
        positions = chain.map { |e| e[:position] }
        expect(emails).to include(email(:kobus_botha))
        expect(emails).to include(email(:sean_bergsma))
        expect(positions).to include('approver_only')
      end

      it 'adds Callie Baney when is_supplier: true' do
        chain  = IgSignatories.chain_for(:iti, 'msa', is_supplier: true)[:stage1]
        emails = chain.map { |e| e[:email] }
        expect(emails).to include(email(:callie_baney))
      end

      it 'does NOT include Callie Baney when is_supplier: false (default)' do
        chain  = IgSignatories.chain_for(:iti, 'msa')[:stage1]
        emails = chain.map { |e| e[:email] }
        expect(emails).not_to include(email(:callie_baney))
      end

      it 'no duplicate emails in any chain' do
        IgEntity.active.pluck(:key).each do |ek|
          chain  = IgSignatories.chain_for(ek, 'msa')[:stage1]
          emails = chain.map { |e| e[:email] }
          expect(emails.uniq).to eq(emails), "Duplicate signatories in #{ek}/msa"
        end
      end
    end

    # ── Active/inactive filtering ──────────────────────────────────────────────

    context 'active/inactive filtering' do
      let!(:william) { IgSignatory.find_by!(email: email(:william_talbot)) }

      after { william.update!(active: true) } # restore after test

      it 'excludes deactivated signatory from chain' do
        william.update!(active: false)
        chain  = IgSignatories.chain_for(:iti, 'msa')[:stage1]
        emails = chain.map { |e| e[:email] }
        expect(emails).not_to include(email(:william_talbot))
      end

      it 'other chain members remain after deactivation' do
        william.update!(active: false)
        chain  = IgSignatories.chain_for(:iti, 'msa')[:stage1]
        emails = chain.map { |e| e[:email] }
        expect(emails).to include(email(:craig_lawrence), email(:laren_farquharson))
      end
    end
  end

  # ── Part 2: CafWorkflow#auto_assign_signatories! ──────────────────────────

  describe CafWorkflow, '#auto_assign_signatories!', type: :model do
    let(:account) { create(:account) }
    let(:user)    { create(:user, account:) }

    def workflow_for(entity:, agreement_type:)
      build(:caf_workflow, entity: entity.to_s, agreement_type:, account:, created_by_user: user)
    end

    context 'field mapping' do
      it 'role is populated from the signatory role_title' do
        wf = workflow_for(entity: :iti, agreement_type: 'msa')
        wf.auto_assign_signatories!
        expect(wf.signatories.first['role']).to be_present
      end

      it 'every signatory has name, email, role, position, chain_position, placeholder=false' do
        wf = workflow_for(entity: :iti, agreement_type: 'msa')
        wf.auto_assign_signatories!
        wf.signatories.each_with_index do |s, idx|
          expect(s['name']).to              be_present, "Signatory #{idx} missing name"
          expect(s['email']).to             be_present, "Signatory #{idx} missing email"
          expect(s['role']).to              be_present, "Signatory #{idx} missing role"
          expect(s['position']).to          eq(idx)
          expect(s['chain_position']).to    be_present, "Signatory #{idx} missing chain_position"
          expect(s['placeholder']).to       eq(false)
        end
      end

      it 'positions are sequential 0-based integers' do
        wf = workflow_for(entity: :iti, agreement_type: 'msa')
        wf.auto_assign_signatories!
        positions = wf.signatories.map { |s| s['position'] }
        expect(positions).to eq((0...wf.signatories.length).to_a)
      end
    end

    context 'NDA' do
      it 'ITI NDA: exactly 1 signatory — Craig Lawrence' do
        wf = workflow_for(entity: :iti, agreement_type: 'nda')
        wf.auto_assign_signatories!
        expect(wf.signatories.length).to eq(1)
        expect(wf.signatories.first['email']).to eq(email(:craig_lawrence))
      end
    end

    context 'Non-NDA' do
      it 'ITI MSA: includes William Talbot, Craig Lawrence, and Sean Bergsma' do
        wf = workflow_for(entity: :iti, agreement_type: 'msa')
        wf.auto_assign_signatories!
        emails = wf.signatories.map { |s| s['email'] }
        expect(emails).to include(
          email(:william_talbot),
          email(:craig_lawrence),
          email(:sean_bergsma)
        )
      end
    end
  end

  # ── Part 3: IgSignatories helper methods ──────────────────────────────────

  describe IgSignatories, 'helper methods' do
    describe '.entity_name' do
      it 'returns the full legal name for a known key' do
        expect(IgSignatories.entity_name(:iti)).to eq('Ignition Telecoms Investments (Pty) Ltd')
      end

      it 'accepts string keys' do
        expect(IgSignatories.entity_name('comit')).to eq('Comit Technologies (Pty) Ltd')
      end

      it 'returns nil for an unknown entity' do
        expect(IgSignatories.entity_name(:nonexistent)).to be_nil
      end
    end

    describe '.all_entity_keys' do
      it 'returns all 9 canonical entity keys' do
        expect(IgSignatories.all_entity_keys.length).to eq(9)
      end

      it 'includes the nine expected keys' do
        expect(IgSignatories.all_entity_keys).to include(
          'iti', 'comit', 'mvnx', 'spot_connect', 'ignition_digital',
          'ignition_cx_us', 'ifs', 'gumtree', 'spot_money'
        )
      end
    end

    describe '.entities_for_js' do
      it 'returns an array with all 9 entities' do
        expect(IgSignatories.entities_for_js.length).to eq(9)
      end

      it 'each entry has key, name, short_name, registration, address' do
        IgSignatories.entities_for_js.each do |e|
          expect(e).to include(:key, :name, :short_name, :registration, :address)
        end
      end
    end

    describe '.person_by_email' do
      it 'returns a hash with name, title, email for a known signatory' do
        result = IgSignatories.person_by_email('Laren.Farquharson@ignitiongroup.co.za')
        expect(result).to include(
          name:  'Laren Farquharson',
          email: 'Laren.Farquharson@ignitiongroup.co.za'
        )
        expect(result[:title]).to be_present
      end

      it 'returns nil for an unknown email' do
        expect(IgSignatories.person_by_email('nobody@example.com')).to be_nil
      end
    end
  end

  # ── Part 4: Hallucinated name purge verification ───────────────────────────

  describe 'hallucinated names are absent from the registry' do
    %w[Megan\ Venter Valde\ Ferradaz John\ Hawthorne Greg\ Goosen].each do |bad_name|
      it "#{bad_name} is not in ig_signatories" do
        expect(IgSignatory.where('full_name ILIKE ?', "%#{bad_name}%")).to be_empty
      end
    end
  end
end
