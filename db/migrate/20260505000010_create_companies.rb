# frozen_string_literal: true

class CreateCompanies < ActiveRecord::Migration[8.1]
  def change
    create_table :companies do |t|
      t.references :account, null: false, foreign_key: true
      t.string  :name,                  null: false
      t.string  :registration_number
      t.string  :primary_contact_name
      t.string  :primary_contact_email
      t.string  :domain
      t.text    :address
      t.string  :country,           default: 'ZA', null: false
      t.integer :agreements_count,  default: 0,    null: false
      t.timestamps
    end

    add_index :companies, %i[account_id name]
    add_index :companies, %i[account_id domain]
  end
end
