# frozen_string_literal: true

class AddDashboardColumnsToCafWorkflows < ActiveRecord::Migration[8.1]
  def change
    # Term
    add_column :caf_workflows, :effective_date,    :date
    add_column :caf_workflows, :expiry_date,        :date
    add_column :caf_workflows, :auto_renewal,       :boolean
    add_column :caf_workflows, :notice_period_days, :integer

    # Cancellation
    add_column :caf_workflows, :cancellation_for_convenience, :string
    add_column :caf_workflows, :cancellation_breach,          :string

    # Limitation of liability
    add_column :caf_workflows, :liability_exclusion_indirect, :string
    add_column :caf_workflows, :liability_cap,                :string

    # Key provisions
    add_column :caf_workflows, :data_protection_clause, :string
    add_column :caf_workflows, :change_of_control,      :string
    add_column :caf_workflows, :ip_ownership,           :string

    # Commercial (currency already exists from add_payment_metrics migration)
    add_column :caf_workflows, :minimum_spend,      :string
    add_column :caf_workflows, :pricing_structure,  :string
    add_column :caf_workflows, :payment_terms_days, :integer
    add_column :caf_workflows, :governing_law,      :string

    # Commercial (continued)
    add_column :caf_workflows, :price_escalation, :string
    add_column :caf_workflows, :exclusivity,      :string
    add_column :caf_workflows, :assignment,       :string

    # Enforcement
    add_column :caf_workflows, :dispute_resolution, :string
    add_column :caf_workflows, :sla_penalties,      :string

    # Operational rights
    add_column :caf_workflows, :renewal_options, :string
    add_column :caf_workflows, :audit_rights,    :string
    add_column :caf_workflows, :subcontracting,  :string

    # Addendum (conditional — only populated when agreement_type = 'Addendum')
    add_column :caf_workflows, :change_in_addendum, :text

    # Provenance tracking: { "payment_terms_days": "ai", "agreement_value": "manual" }
    add_column :caf_workflows, :parsed_data_provenance, :jsonb, default: {}

    # Indexes for dashboard queries
    add_index :caf_workflows, :expiry_date
    add_index :caf_workflows, :auto_renewal
    add_index :caf_workflows, :change_of_control
    add_index :caf_workflows, %i[entity status]
    add_index :caf_workflows, %i[account_id expiry_date]
  end
end
