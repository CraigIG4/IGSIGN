# frozen_string_literal: true

module LegalOps
  # Admin UI for the IGSIGN signatory registry.
  # Lists all signatories and their entity assignments.
  # Admins can toggle active status or update role_title.
  # Email and full_name are read-only (too high-risk to rename via UI).
  class SignatoriesController < ApplicationController
    before_action :authenticate_user!
    before_action :require_admin!
    before_action :set_signatory, only: %i[edit update toggle_active]

    def index
      @entities    = IgEntity.active.ordered.includes(ig_entity_signatories: :ig_signatory)
      @signatories = IgSignatory.ordered.includes(:ig_entity_signatories, :ig_entities)
    end

    def edit; end

    def update
      if @signatory.update(signatory_params)
        redirect_to legal_ops_signatories_path,
                    notice: "#{@signatory.full_name} updated."
      else
        render :edit, status: :unprocessable_entity
      end
    end

    def toggle_active
      @signatory.update!(active: !@signatory.active)
      status_label = @signatory.active? ? 'activated' : 'deactivated'
      redirect_to legal_ops_signatories_path,
                  notice: "#{@signatory.full_name} #{status_label}."
    end

    private

    def require_admin!
      redirect_to root_path, alert: 'Not authorised.' unless current_user.role == User::ADMIN_ROLE
    end

    def set_signatory
      @signatory = IgSignatory.find(params[:id])
    end

    def signatory_params
      # email and full_name are intentionally excluded — read-only via UI
      params.require(:ig_signatory).permit(:role_title, :seniority)
    end
  end
end
