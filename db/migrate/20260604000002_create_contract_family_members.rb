# frozen_string_literal: true

class CreateContractFamilyMembers < ActiveRecord::Migration[8.1]
  def change
    create_table :contract_family_members do |t|
      t.references :caf_workflow,    null: false, foreign_key: true
      t.references :linked_workflow, foreign_key: { to_table: :caf_workflows }
      t.string  :document_name, null: false
      t.string  :role     # 'master', 'schedule', 'sow', 'addendum', 'nda'
      t.integer :position, default: 0
      t.timestamps
    end

    add_index :contract_family_members, %i[caf_workflow_id linked_workflow_id], unique: true,
              name: 'index_contract_family_members_unique'
  end
end
