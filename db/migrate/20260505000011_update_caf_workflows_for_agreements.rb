# frozen_string_literal: true

class UpdateCafWorkflowsForAgreements < ActiveRecord::Migration[8.1]
  def change
    add_column    :caf_workflows, :agreement_type, :string
    add_reference :caf_workflows, :company,  foreign_key: true
    add_reference :caf_workflows, :template, foreign_key: true

    reversible do |dir|
      dir.up do
        execute <<~SQL
          UPDATE caf_workflows
          SET agreement_type = CASE
            WHEN caf_type = 'nda'        THEN 'nda'
            WHEN caf_type = 'short_form' THEN 'addendum'
            ELSE 'msa'
          END
          WHERE agreement_type IS NULL
        SQL
      end
    end
  end
end
