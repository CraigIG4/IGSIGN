# frozen_string_literal: true

class AddWalkthroughCompletedAtToUsers < ActiveRecord::Migration[8.1]
  def change
    add_column :users, :walkthrough_completed_at, :datetime
  end
end
