# frozen_string_literal: true

class AddParsedContractDataToCafWorkflows < ActiveRecord::Migration[7.1]
  def change
    add_column :caf_workflows, :parsed_contract_data, :jsonb
    add_index  :caf_workflows, :parsed_contract_data, using: :gin
  end
end
