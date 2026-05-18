# frozen_string_literal: true

# Sender-facing template library.  Replaces DocuSeal's templates_dashboard index
# at GET /templates.
#
# Admins are redirected to /admin/templates (the management view).
# Senders see two sections:
#
#   1. NDA — one card per IG entity (13 cards), linking to new_agreement with
#      agreement_type=nda&entity=<key> pre-set.  Cards are shown for every
#      IgSignatories entity regardless of whether an active metadata record
#      exists — the NDA can still proceed via dynamic generation.
#
#   2. Upload Agreement — single entry point to start an agreement from an
#      uploaded document (non-NDA types: msa, sla, vendor, employment, etc.).
#
# CAF templates (short_form_caf, long_form_caf) are admin-only and are NOT
# shown here — senders never choose the CAF template directly.
class TemplatesLibraryController < ApplicationController
  skip_authorization_check
  before_action :authenticate_user!

  def index
    # Admin users go to the management view instead
    if current_user.role == User::ADMIN_ROLE
      redirect_to admin_templates_path and return
    end

    # Build the 13 entity cards for the NDA section.
    # Each card carries the entity key, display name, short name, and whether
    # an active NDA metadata record exists for this account + entity.
    active_entity_keys = IgsignTemplateMetadata
                           .active
                           .where(kind: 'nda')
                           .joins(:template)
                           .where(templates: { account_id: current_account.id })
                           .pluck('entity_scope')
                           .flatten
                           .to_set

    @nda_entities = IgSignatories::ENTITIES.map do |key, details|
      {
        key:        key.to_s,
        name:       details[:name],
        short_name: details[:short_name],
        active:     active_entity_keys.include?(key.to_s)
      }
    end
  end
end
