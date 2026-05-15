# frozen_string_literal: true

# Sender-facing template library.  Replaces DocuSeal's templates_dashboard index
# at GET /templates.
#
# Admins are redirected to /admin/templates (the management view).
# All other authenticated users see a browse-by-kind card grid of Active templates.
# Clicking a template card starts a new agreement with that template pre-selected.
class TemplatesLibraryController < ApplicationController
  skip_authorization_check
  before_action :authenticate_user!

  def index
    # Admin users go to the management view instead
    if current_user.role == User::ADMIN_ROLE
      redirect_to admin_templates_path and return
    end

    # Fetch active templates that have IGSIGN metadata
    base = current_account.templates
             .where(archived_at: nil)
             .joins(:igsign_metadata)
             .where(igsign_template_metadata: { status: 'active' })
             .includes(:igsign_metadata, :author)
             .order('igsign_template_metadata.kind, templates.name')

    @templates_by_kind = base.group_by { |t| t.igsign_metadata.kind }

    # Also surface templates with no metadata so nothing is hidden from senders
    @untagged = current_account.templates
                  .where(archived_at: nil)
                  .where.missing(:igsign_metadata)
                  .includes(:author)
                  .order(:name)

    @kind_labels = IgsignTemplateMetadata::KIND_LABELS
  end
end
