# frozen_string_literal: true

class AddPaymentMetricsToCafWorkflows < ActiveRecord::Migration[8.1]
  def change
    add_column :caf_workflows, :currency,             :string, default: 'ZAR'
    add_column :caf_workflows, :payment_metric_type,  :string
    add_column :caf_workflows, :seat_cost,            :string
    add_column :caf_workflows, :training_cost,        :string
    add_column :caf_workflows, :number_of_seats,      :string
  end
end
