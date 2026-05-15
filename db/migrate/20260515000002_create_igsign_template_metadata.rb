# frozen_string_literal: true

# Thin IGSIGN metadata layer on top of DocuSeal's templates table.
# Intentionally separate so that DocuSeal's own template machinery is untouched.
# Each DocuSeal Template may have at most one IgsignTemplateMetadata record;
# the record is created (as status 'draft') the first time an admin visits
# Admin::TemplatesController#edit_metadata, or explicitly via "+ New IGSIGN Template".
class CreateIgsignTemplateMetadata < ActiveRecord::Migration[8.1]
  def change
    create_table :igsign_template_metadata do |t|
      t.bigint  :template_id,  null: false
      t.bigint  :owner_id                      # FK to users; null = unassigned
      t.string  :kind,         null: false, default: 'other'
      t.integer :version,      null: false, default: 1
      t.string  :status,       null: false, default: 'draft'
      t.text    :notes
      t.timestamps
    end

    add_index :igsign_template_metadata, :template_id, unique: true
    add_index :igsign_template_metadata, :owner_id
    add_index :igsign_template_metadata, :kind
    add_index :igsign_template_metadata, :status

    add_foreign_key :igsign_template_metadata, :templates
    add_foreign_key :igsign_template_metadata, :users, column: :owner_id
  end
end
