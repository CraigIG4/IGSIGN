# frozen_string_literal: true

require 'rails_helper'

RSpec.describe CafFieldSchema do
  describe '.field' do
    it 'returns the field hash for a known key' do
      field = described_class.field(:contract_type)
      expect(field).to be_a(Hash)
      expect(field[:key]).to eq(:contract_type)
      expect(field[:caf_column]).to eq(:agreement_type)
    end

    it 'returns nil for an unknown key' do
      expect(described_class.field(:nonexistent)).to be_nil
    end
  end

  describe '.dashboard_fields' do
    it 'returns only fields with dashboard: true' do
      fields = described_class.dashboard_fields
      expect(fields).to all(satisfy { |f| f[:dashboard] == true })
    end

    it 'includes contract_type and expiry_date' do
      keys = described_class.dashboard_fields.map { |f| f[:key] }
      expect(keys).to include(:contract_type, :expiry_date, :governing_law)
    end
  end

  describe '.caf_column_fields' do
    it 'returns fields that have a caf_column' do
      fields = described_class.caf_column_fields
      expect(fields).to all(satisfy { |f| f[:caf_column].present? })
    end

    it 'excludes amends_or_relates_to (jsonb only)' do
      keys = described_class.caf_column_fields.map { |f| f[:key] }
      expect(keys).not_to include(:amends_or_relates_to)
    end
  end

  describe '.active_fields_for_type' do
    it 'includes change_in_addendum when contract_type is Addendum' do
      keys = described_class.active_fields_for_type('Addendum').map { |f| f[:key] }
      expect(keys).to include(:change_in_addendum)
    end

    it 'excludes change_in_addendum when contract_type is MSA' do
      keys = described_class.active_fields_for_type('MSA').map { |f| f[:key] }
      expect(keys).not_to include(:change_in_addendum)
    end

    it 'excludes change_in_addendum when contract_type is blank' do
      keys = described_class.active_fields_for_type('').map { |f| f[:key] }
      expect(keys).not_to include(:change_in_addendum)
    end

    it 'returns all non-conditional fields regardless of type' do
      keys = described_class.active_fields_for_type('NDA').map { |f| f[:key] }
      expect(keys).to include(:high_level_summary, :effective_date, :governing_law)
    end
  end

  describe '.active_fields_for' do
    let(:workflow) { instance_double(CafWorkflow, contract_type: 'Addendum') }
    let(:non_addendum_workflow) { instance_double(CafWorkflow, contract_type: 'MSA') }

    it 'includes change_in_addendum for an Addendum workflow' do
      keys = described_class.active_fields_for(workflow).map { |f| f[:key] }
      expect(keys).to include(:change_in_addendum)
    end

    it 'excludes change_in_addendum for a non-Addendum workflow' do
      keys = described_class.active_fields_for(non_addendum_workflow).map { |f| f[:key] }
      expect(keys).not_to include(:change_in_addendum)
    end
  end
end
