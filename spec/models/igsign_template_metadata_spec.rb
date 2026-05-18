# frozen_string_literal: true

require 'rails_helper'

RSpec.describe IgsignTemplateMetadata, type: :model do
  let(:account) { create(:account) }
  let(:user)    { create(:user, account: account) }

  def make_template(name: 'Test Template')
    create(:template, account: account, author: user, name: name)
  end

  def make_meta(template:, kind:, status:, entity_scope: [])
    create(:igsign_template_metadata,
           template:     template,
           kind:         kind,
           status:       status,
           entity_scope: entity_scope)
  end

  # ---------------------------------------------------------------------------
  describe 'KINDS constant' do
    it 'contains exactly the three consolidated kinds' do
      expect(described_class::KINDS).to match_array(%w[nda short_form_caf long_form_caf])
    end

    it 'does not contain legacy kinds' do
      %w[msa sla vendor employment addendum policy other].each do |legacy|
        expect(described_class::KINDS).not_to include(legacy)
      end
    end
  end

  # ---------------------------------------------------------------------------
  describe 'validations' do
    it 'is valid with kind nda, status draft, version 1' do
      meta = build(:igsign_template_metadata, template: make_template, kind: 'nda',
                                              status: 'draft', version: 1)
      expect(meta).to be_valid
    end

    it 'rejects an unknown kind' do
      meta = build(:igsign_template_metadata, template: make_template, kind: 'msa')
      expect(meta).not_to be_valid
      expect(meta.errors[:kind]).to be_present
    end

    it 'rejects an unknown status' do
      meta = build(:igsign_template_metadata, template: make_template, status: 'pending')
      expect(meta).not_to be_valid
    end
  end

  # ---------------------------------------------------------------------------
  describe '.entity_nda_for' do
    it 'returns the entity-specific active NDA record' do
      tpl  = make_template
      meta = make_meta(template: tpl, kind: 'nda', status: 'active', entity_scope: ['iti'])
      make_meta(template: make_template(name: 'Other'), kind: 'nda', status: 'active',
                entity_scope: ['comit'])

      result = described_class.entity_nda_for(account, 'iti')
      expect(result).to eq(meta)
    end

    it 'falls back to any active NDA when no entity-specific record exists' do
      tpl  = make_template
      meta = make_meta(template: tpl, kind: 'nda', status: 'active', entity_scope: [])

      result = described_class.entity_nda_for(account, 'iti')
      expect(result).to eq(meta)
    end

    it 'returns nil when no active NDA exists' do
      make_meta(template: make_template, kind: 'nda', status: 'draft', entity_scope: ['iti'])
      expect(described_class.entity_nda_for(account, 'iti')).to be_nil
    end

    it 'does not return records belonging to a different account' do
      other_account = create(:account)
      other_user    = create(:user, account: other_account)
      other_tpl     = create(:template, account: other_account, author: other_user)
      make_meta(template: other_tpl, kind: 'nda', status: 'active', entity_scope: ['iti'])

      expect(described_class.entity_nda_for(account, 'iti')).to be_nil
    end

    it 'prefers entity-specific over generic fallback' do
      make_meta(template: make_template(name: 'Generic'), kind: 'nda',
                status: 'active', entity_scope: [])
      specific = make_meta(template: make_template(name: 'ITI'), kind: 'nda',
                           status: 'active', entity_scope: ['iti'])

      expect(described_class.entity_nda_for(account, 'iti')).to eq(specific)
    end
  end

  # ---------------------------------------------------------------------------
  describe '#kind_label' do
    {
      'nda'            => 'NDA',
      'short_form_caf' => 'Short-form CAF',
      'long_form_caf'  => 'Long-form CAF'
    }.each do |kind, expected_label|
      it "returns '#{expected_label}' for kind '#{kind}'" do
        meta = build(:igsign_template_metadata, template: make_template, kind: kind)
        expect(meta.kind_label).to eq(expected_label)
      end
    end
  end

  # ---------------------------------------------------------------------------
  describe '.for_template' do
    it 'finds existing metadata for the template' do
      tpl  = make_template
      meta = make_meta(template: tpl, kind: 'nda', status: 'draft')
      expect(described_class.for_template(tpl)).to eq(meta)
    end

    it 'initialises a new (unsaved) record when none exists' do
      tpl    = make_template
      result = described_class.for_template(tpl)
      expect(result).to be_new_record
      expect(result.template).to eq(tpl)
    end
  end
end
