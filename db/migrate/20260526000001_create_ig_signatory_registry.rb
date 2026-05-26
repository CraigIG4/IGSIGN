# frozen_string_literal: true

class CreateIgSignatoryRegistry < ActiveRecord::Migration[8.0]
  def change
    # ── IG Entities (the legal entities that sign agreements) ─────────────────
    create_table :ig_entities do |t|
      t.string  :key,                 null: false
      t.string  :name,                null: false
      t.string  :display_name
      t.string  :registration_number
      t.text    :registered_address
      t.boolean :active,              null: false, default: true
      t.timestamps
    end
    add_index :ig_entities, :key, unique: true

    # ── IG Signatories (real people authorised to sign) ───────────────────────
    create_table :ig_signatories do |t|
      t.string  :full_name,  null: false
      t.string  :email,      null: false
      t.string  :role_title
      t.string  :seniority              # 'Executive' or 'Senior Manager'
      t.boolean :active,     null: false, default: true
      t.timestamps
    end
    add_index :ig_signatories, :email, unique: true

    # ── Join: which person plays which role for which entity ──────────────────
    #
    # position values:
    #   bu_head             BU Head for this entity (Stage 0 approver)
    #   bu_cfo              BU CFO for this entity (Stage 0 approver)
    #   bu_cfo_alternate    Alternate BU CFO (fallback if primary inactive)
    #   group_clo           Group CLO — Craig Lawrence (Stage 0, all entities)
    #   group_cfo           Group CFO — Laren Farquharson (Stage 0, all entities)
    #   group_ceo           Group CEO — used for Stage 1 signing (Sean Bergsma default)
    #   group_coo           Group COO — alternate Stage 1 signer (Don Bergsma)
    #   group_signer        Stage 1 group signer for this entity
    #   group_signer_alt    Alternate Stage 1 signer (e.g. Spot Connect: Siddeek first)
    #   approver_only       Stage 0 approver only — not Stage 1 signer (Sean for IFS)
    #   procurement         Procurement approver — Callie Baney (added if supplier)
    create_table :ig_entity_signatories do |t|
      t.references :ig_entity,    null: false, foreign_key: true
      t.references :ig_signatory, null: false, foreign_key: true
      t.string     :position,     null: false
      t.boolean    :active,       null: false, default: true
      t.text       :notes
      t.timestamps
    end
    add_index :ig_entity_signatories,
              %i[ig_entity_id ig_signatory_id position],
              unique: true,
              name:   'idx_entity_signatory_position'
  end
end
