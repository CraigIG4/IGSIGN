# frozen_string_literal: true

# Admin template metadata management.
# Lists all DocuSeal templates for this account plus IGSIGN metadata.
# Admins assign kind, owner, status, and notes; click-through to DocuSeal editor
# for actual field positioning.
#
# Routes:
#   GET    /admin/templates           index
#   GET    /admin/templates/new       new  (creates DocuSeal template + metadata)
#   POST   /admin/templates           create
#   GET    /admin/templates/:id/edit  edit metadata
#   PATCH  /admin/templates/:id       update metadata
#   PATCH  /admin/templates/:id/activate
#   PATCH  /admin/templates/:id/deprecate
module Admin
  class TemplatesController < ApplicationController
    skip_authorization_check
    before_action :authenticate_user!
    before_action :require_admin!
    before_action :set_template,  only: %i[edit update activate deprecate]
    before_action :set_metadata,  only: %i[edit update activate deprecate]

    def index
      @templates = current_account
                     .templates
                     .where(archived_at: nil)
                     .includes(:author, :igsign_metadata)
                     .order(updated_at: :desc)

      # Group stats for the hero header
      meta_scope = IgsignTemplateMetadata.joins(:template)
                     .where(templates: { account_id: current_account.id, archived_at: nil })
      @stats = {
        total:      @templates.count,
        active:     meta_scope.where(status: 'active').count,
        draft:      meta_scope.where(status: 'draft').count,
        deprecated: meta_scope.where(status: 'deprecated').count,
        no_meta:    @templates.count - meta_scope.count
      }
    end

    def new
      # Redirect to DocuSeal's native new-template flow; on return the template
      # will appear in the index where admin can edit metadata.
      redirect_to new_template_path,
                  notice: 'Create the template below, then return here to assign IGSIGN metadata.'
    end

    def create
      # This action handles the metadata-only create (POST from the metadata form
      # on a template that exists but has no metadata record yet).
      @template = current_account.templates.find(params[:template_id])
      @metadata = IgsignTemplateMetadata.new(metadata_params)
      @metadata.template = @template

      if @metadata.save
        redirect_to admin_templates_path,
                    notice: "Metadata saved for \"#{@template.name}\"."
      else
        @templates = current_account.templates.where(archived_at: nil)
                       .includes(:author, :igsign_metadata).order(updated_at: :desc)
        render :index, status: :unprocessable_entity
      end
    end

    def edit; end

    def update
      was_active = @metadata.active?

      if @metadata.update(metadata_params)
        # Bump version only when content changes on an already-active record
        @metadata.bump_version! if was_active

        redirect_to admin_templates_path,
                    notice: "\"#{@template.name}\" metadata updated (v#{@metadata.reload.version})."
      else
        render :edit, status: :unprocessable_entity
      end
    end

    def activate
      if @metadata.update(status: 'active')
        redirect_to admin_templates_path,
                    notice: "\"#{@template.name}\" is now Active."
      else
        redirect_to admin_templates_path,
                    alert: "Could not activate \"#{@template.name}\"."
      end
    end

    def deprecate
      if @metadata.update(status: 'deprecated')
        redirect_to admin_templates_path,
                    notice: "\"#{@template.name}\" marked Deprecated."
      else
        redirect_to admin_templates_path,
                    alert: "Could not deprecate \"#{@template.name}\"."
      end
    end

    private

    def require_admin!
      redirect_to root_path, alert: 'Not authorised.' unless current_user.role == User::ADMIN_ROLE
    end

    def set_template
      @template = current_account.templates.find(params[:id])
    end

    def set_metadata
      @metadata = IgsignTemplateMetadata.for_template(@template)
    end

    def metadata_params
      params.require(:igsign_template_metadata).permit(:kind, :owner_id, :status, :notes)
    end
  end
end
