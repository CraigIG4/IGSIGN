# frozen_string_literal: true

class AddStatusUpdatedAtToCafWorkflows < ActiveRecord::Migration[8.1]
  def change
    add_column :caf_workflows, :status_updated_at, :datetime

    # Back-fill so existing rows have a non-nil value.  created_at is the best
    # approximation for rows that were created before this column existed.
    reversible do |dir|
      dir.up do
        execute <<~SQL
          UPDATE caf_workflows
          SET status_updated_at = updated_at
          WHERE status_updated_at IS NULL
        SQL
      end
    end

    add_index :caf_workflows, :status_updated_at
  end
end
