# frozen_string_literal: true

require 'rails_helper'

RSpec.describe ContractFamilyMember, type: :model do
  let(:account) { create(:account) }
  let(:user)    { create(:user, account: account) }
  let(:workflow) { create(:caf_workflow, account: account, created_by_user: user) }
  let(:other_workflow) { create(:caf_workflow, account: account, created_by_user: user) }

  describe 'validations' do
    it 'is valid with a document_name' do
      member = workflow.contract_family_members.build(document_name: 'Test MSA')
      expect(member).to be_valid
    end

    it 'is invalid without a document_name' do
      member = workflow.contract_family_members.build
      expect(member).not_to be_valid
      expect(member.errors[:document_name]).to be_present
    end

    it 'enforces uniqueness of linked_workflow per caf_workflow' do
      workflow.contract_family_members.create!(
        document_name: 'MSA', linked_workflow: other_workflow
      )
      duplicate = workflow.contract_family_members.build(
        document_name: 'MSA copy', linked_workflow: other_workflow
      )
      expect(duplicate).not_to be_valid
      expect(duplicate.errors[:linked_workflow_id]).to be_present
    end

    it 'allows nil linked_workflow_id (unlinked manual entry)' do
      member = workflow.contract_family_members.build(document_name: 'External MSA')
      expect(member).to be_valid
    end

    it 'validates role inclusion when present' do
      member = workflow.contract_family_members.build(
        document_name: 'Test', role: 'invalid_role'
      )
      expect(member).not_to be_valid
      expect(member.errors[:role]).to be_present
    end

    it 'accepts all valid roles' do
      ContractFamilyMember::ROLES.each do |role|
        member = workflow.contract_family_members.build(document_name: 'Test', role: role)
        expect(member).to be_valid, "Expected #{role} to be valid"
      end
    end

    it 'accepts nil role' do
      member = workflow.contract_family_members.build(document_name: 'Test', role: nil)
      expect(member).to be_valid
    end
  end

  describe 'associations' do
    it 'belongs to caf_workflow' do
      member = workflow.contract_family_members.create!(document_name: 'Test')
      expect(member.caf_workflow).to eq(workflow)
    end

    it 'belongs to linked_workflow (optional)' do
      member = workflow.contract_family_members.create!(
        document_name: 'Test MSA', linked_workflow: other_workflow
      )
      expect(member.linked_workflow).to eq(other_workflow)
    end

    it 'is destroyed when parent caf_workflow is destroyed' do
      workflow.contract_family_members.create!(document_name: 'Test')
      expect { workflow.destroy! }.to change(ContractFamilyMember, :count).by(-1)
    end
  end

  describe 'CafWorkflow associations' do
    it 'caf_workflow has many contract_family_members' do
      workflow.contract_family_members.create!(document_name: 'MSA 1')
      workflow.contract_family_members.create!(document_name: 'SOW 1')
      expect(workflow.contract_family_members.count).to eq(2)
    end

    it 'caf_workflow has many linked_workflows through contract_family_members' do
      workflow.contract_family_members.create!(
        document_name: 'Linked MSA', linked_workflow: other_workflow
      )
      expect(workflow.linked_workflows).to include(other_workflow)
    end
  end

  describe '.ordered scope' do
    it 'orders by position then created_at' do
      m2 = workflow.contract_family_members.create!(document_name: 'B', position: 2)
      m1 = workflow.contract_family_members.create!(document_name: 'A', position: 1)
      expect(workflow.contract_family_members.ordered.first).to eq(m1)
      expect(workflow.contract_family_members.ordered.last).to eq(m2)
    end
  end
end
