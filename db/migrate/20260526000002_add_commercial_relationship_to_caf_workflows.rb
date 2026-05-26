# frozen_string_literal: true

class AddCommercialRelationshipToCafWorkflows < ActiveRecord::Migration[7.1]
  def change
    add_column :caf_workflows, :commercial_relationship, :integer, default: 0, null: false
    add_index  :caf_workflows, :commercial_relationship
  end
end
