# frozen_string_literal: true

# IGSIGN — IG entity registry and signatory chains
#
# Post-26-May-2026: all data is database-backed (ig_entities, ig_signatories,
# ig_entity_signatories). The old hardcoded PEOPLE and ENTITIES constants are
# removed. Canonical data lives in db/seeds/igsign_registry.rb.
#
# Public API (stable — callers must not be changed without updating this module):
#
#   IgSignatories.chain_for(entity_key, agreement_type, is_supplier: false)
#     → { stage1: [{ name:, title:, email:, position: }], stage2: [] }
#
#   IgSignatories.entity_name(entity_key)     → String or nil
#   IgSignatories.entity_details(entity_key)  → IgEntity or nil
#   IgSignatories.person_by_email(email)      → { name:, title:, email: } or nil
#   IgSignatories.entities_for_js             → Array of hashes
#   IgSignatories.all_entity_keys             → Array of String keys

module IgSignatories
  REGISTERED_ADDRESS = "Quadrant 4, Centenary Building, 30 Meridian Drive\n" \
                       "Umhlanga, KwaZulu-Natal, South Africa".freeze

  # ---------------------------------------------------------------------------
  # chain_for — the core API
  # ---------------------------------------------------------------------------
  #
  # Returns the signing chain for an entity + agreement type combination.
  #
  # entity_key:      String or Symbol e.g. "iti", :comit
  # agreement_type:  String or Symbol — the agreement type (nda, msa, vendor, etc.)
  # is_supplier:     Boolean — whether the counterparty is a supplier
  #                  (adds Procurement approver to Stage 0 when true)
  #
  # Return value: { stage1: Array, stage2: [] }
  # stage1 contains all signing chain members in order:
  #   BU Head, BU CFO, Group CLO, Group CFO, [Procurement if supplier], Group Signer
  # For NDA: stage1 contains Craig Lawrence (Group CLO) only.
  #
  # Each entry: { name: String, title: String, email: String, position: String }
  # ---------------------------------------------------------------------------
  def self.chain_for(entity_key, agreement_type, is_supplier: false)
    entity = IgEntity.find_by(key: entity_key.to_s)
    return { stage1: [], stage2: [] } unless entity

    if agreement_type.to_s == 'nda'
      # NDAs: Craig Lawrence alone in Stage 0. No Stage 1. Direct to counterparty.
      clo_sigs = active_sigs_for(entity, 'group_clo')
      return { stage1: clo_sigs, stage2: [] }
    end

    # All other agreement types: build full chain in prescribed order
    positions = %w[bu_head bu_cfo bu_cfo_alternate group_clo group_cfo group_coo]
    positions << 'procurement' if is_supplier
    positions += %w[approver_only group_signer group_signer_alt]

    sigs = entity.ig_entity_signatories
                 .active
                 .includes(:ig_signatory)
                 .select { |jes| positions.include?(jes.position) && jes.ig_signatory.active? }
                 .sort_by { |jes| positions.index(jes.position) }
                 .map { |jes| signatory_to_hash(jes.ig_signatory, jes.position) }

    { stage1: sigs, stage2: [] }
  end

  # ---------------------------------------------------------------------------
  # entity_name
  # ---------------------------------------------------------------------------
  def self.entity_name(entity_key)
    IgEntity.find_by(key: entity_key.to_s)&.name
  end

  # ---------------------------------------------------------------------------
  # entity_details — returns the IgEntity record (or nil)
  # ---------------------------------------------------------------------------
  def self.entity_details(entity_key)
    IgEntity.find_by(key: entity_key.to_s)
  end

  # ---------------------------------------------------------------------------
  # person_by_email — looks up a signatory by email address
  # Returns a legacy-style hash { name:, title:, email: } for compatibility
  # with callers that used IgSignatories.person(:laren_farquharson)
  # ---------------------------------------------------------------------------
  def self.person_by_email(email)
    sig = IgSignatory.find_by(email: email)
    return nil unless sig

    { name: sig.full_name, title: sig.role_title.to_s, email: sig.email }
  end

  # ---------------------------------------------------------------------------
  # all_entity_keys — for use in validations (replaces ENTITIES.keys.map(&:to_s))
  # ---------------------------------------------------------------------------
  def self.all_entity_keys
    IgEntity.active.pluck(:key)
  end

  # ---------------------------------------------------------------------------
  # entities_for_js — serialised entity list for front-end use
  # ---------------------------------------------------------------------------
  def self.entities_for_js
    IgEntity.active.ordered.map do |e|
      {
        key:              e.key,
        name:             e.name,
        short_name:       e.short_name,
        registration:     e.registration_number.to_s,
        address:          e.registered_address || REGISTERED_ADDRESS
      }
    end
  end

  # ---------------------------------------------------------------------------
  # Private helpers
  # ---------------------------------------------------------------------------
  class << self
    private

    def active_sigs_for(entity, position)
      entity.ig_entity_signatories
            .active
            .where(position: position)
            .includes(:ig_signatory)
            .filter_map { |jes|
              next unless jes.ig_signatory.active?

              signatory_to_hash(jes.ig_signatory, position)
            }
    end

    def signatory_to_hash(sig, position)
      {
        name:     sig.full_name,
        title:    sig.role_title.to_s,
        email:    sig.email,
        position: position
      }
    end
  end
end
