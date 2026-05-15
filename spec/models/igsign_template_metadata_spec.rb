# frozen_string_literal: true

require 'rails_helper'

RSpec.describe IgsignTemplateMetadata, type: :model do
  let(:user)     { create(:user) }
  let(:account)  { user.account }
  let(:template) { create(:template, author: user, account: account) }

  subject(:meta) { build(:igsign_template_metadata, template: template, owner: user) }

  # ── Validations ──────────────────────────────────────────────────────────────

  describe 'validations' do
    it { is_expected.to be_valid }

    it 'requires kind' do
      meta.kind = nil
      expect(meta).not_to be_valid
    end

    it 'rejects unknown kind' do
      meta.kind = 'galactic_treaty'
      expect(meta).not_to be_valid
      expect(meta.errors[:kind]).to be_present
    end

    it 'requires status' do
      meta.status = nil
      expect(meta).not_to be_valid
    end

    it 'rejects unknown status' do
      meta.status = 'limbo'
      expect(meta).not_to be_valid
    end

    it 'requires version > 0' do
      meta.version = 0
      expect(meta).not_to be_valid
    end

    it 'is unique per template' do
      create(:igsign_template_metadata, template: template)
      duplicate = build(:igsign_template_metadata, template: template)
      expect(duplicate).not_to be_valid
    end
  end

  # ── Status helpers ────────────────────────────────────────────────────────────

  describe 'status predicates' do
    it '#active? returns true for active' do
      meta.status = 'active'
      expect(meta.active?).to be(true)
    end

    it '#deprecated? returns true for deprecated' do
      meta.status = 'deprecated'
      expect(meta.deprecated?).to be(true)
    end

    it '#draft? returns true for draft' do
      meta.status = 'draft'
      expect(meta.draft?).to be(true)
    end
  end

  # ── Labels ───────────────────────────────────────────────────────────────────

  describe '#kind_label' do
    it 'returns human-readable label' do
      meta.kind = 'nda'
      expect(meta.kind_label).to eq('NDA')
    end
  end

  describe '#status_label' do
    it 'returns human-readable label' do
      meta.status = 'active'
      expect(meta.status_label).to eq('Active')
    end
  end

  # ── bump_version! ────────────────────────────────────────────────────────────

  describe '#bump_version!' do
    it 'increments version by 1' do
      meta.save!
      expect { meta.bump_version! }.to change { meta.reload.version }.by(1)
    end
  end

  # ── .for_template ─────────────────────────────────────────────────────────────

  describe '.for_template' do
    it 'returns existing record if present' do
      saved = create(:igsign_template_metadata, template: template)
      expect(described_class.for_template(template)).to eq(saved)
    end

    it 'returns a new unsaved record if none exists' do
      result = described_class.for_template(template)
      expect(result).to be_a(described_class)
      expect(result).to be_new_record
    end
  end

  # ── Scopes ────────────────────────────────────────────────────────────────────

  describe 'scopes' do
    let!(:active_meta)     { create(:igsign_template_metadata, template: template, status: 'active') }
    let!(:draft_template)  { create(:template, author: user, account: account) }
    let!(:draft_meta)      { create(:igsign_template_metadata, template: draft_template, status: 'draft') }
    let!(:depr_template)   { create(:template, author: user, account: account) }
    let!(:depr_meta)       { create(:igsign_template_metadata, template: depr_template, status: 'deprecated') }

    it '.active includes only active' do
      expect(described_class.active).to include(active_meta)
      expect(described_class.active).not_to include(draft_meta, depr_meta)
    end

    it '.not_deprecated excludes deprecated' do
      expect(described_class.not_deprecated).to include(active_meta, draft_meta)
      expect(described_class.not_deprecated).not_to include(depr_meta)
    end
  end
end
