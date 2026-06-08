# frozen_string_literal: true

class AddPaymentTermsStructuredToCafWorkflows < ActiveRecord::Migration[8.1]
  def change
    add_column :caf_workflows, :payment_terms_structured, :jsonb, default: []
  end
end
