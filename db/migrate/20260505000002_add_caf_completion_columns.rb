# frozen_string_literal: true
class AddCafCompletionColumns < ActiveRecord::Migration[7.1]
  def change
    # Track when individual CAF stages complete
    add_column :caf_stages, :completed_at, :datetime, if_not_exists: true

    # Track when internal-only CAF pages are stripped
    add_column :caf_stage_documents, :stripped_at, :datetime, if_not_exists: true
  end
end
