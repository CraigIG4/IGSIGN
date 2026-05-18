# frozen_string_literal: true

# Prompt 4 — Template kind consolidation + per-entity NDA scope
#
# 1. Adds entity_scope :jsonb to igsign_template_metadata.
#    Stores an array of IgSignatories entity keys (e.g. ["iti"]).
#    Empty array means "applies to all entities" (non-NDA or global templates).
#
# 2. Collapses the 8 legacy kind values down to 3:
#      nda                                → nda           (unchanged)
#      msa | sla | vendor | employment    → long_form_caf
#      addendum | policy | other          → short_form_caf
#
#    NDA metadata records also get entity_scope populated from the IGSIGN NDA
#    Template (one record → all 13 entities after the seed task runs).  The
#    data migration leaves existing records with an empty array so admins can
#    populate entity_scope as part of template activation.
#
# 3. Adds a GIN index on entity_scope for the @> containment query used by
#    IgsignTemplateMetadata.entity_nda_for(account, entity_key).
class AddEntityScopeAndConsolidateKinds < ActiveRecord::Migration[8.1]
  LONG_FORM_KINDS   = %w[msa sla vendor employment].freeze
  SHORT_FORM_KINDS  = %w[addendum policy other].freeze

  def up
    add_column :igsign_template_metadata, :entity_scope, :jsonb, null: false, default: []

    add_index :igsign_template_metadata, :entity_scope,
              using: :gin,
              name:  'index_igsign_template_metadata_on_entity_scope'

    # Remap legacy kinds — safe even if the table is empty
    execute <<~SQL
      UPDATE igsign_template_metadata
         SET kind = 'long_form_caf'
       WHERE kind IN ('msa', 'sla', 'vendor', 'employment')
    SQL

    execute <<~SQL
      UPDATE igsign_template_metadata
         SET kind = 'short_form_caf'
       WHERE kind IN ('addendum', 'policy', 'other')
    SQL
  end

  def down
    remove_index :igsign_template_metadata, name: 'index_igsign_template_metadata_on_entity_scope'
    remove_column :igsign_template_metadata, :entity_scope

    # Best-effort reversal: long_form_caf → msa, short_form_caf → addendum.
    # Full fidelity is not possible because the original kind is gone.
    execute <<~SQL
      UPDATE igsign_template_metadata SET kind = 'msa'      WHERE kind = 'long_form_caf'
    SQL
    execute <<~SQL
      UPDATE igsign_template_metadata SET kind = 'addendum' WHERE kind = 'short_form_caf'
    SQL
  end
end
