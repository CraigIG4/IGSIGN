# frozen_string_literal: true

# Landing page for the Legal Ops section.
# Renders a card grid linking to each sub-section.
module LegalOps
  class DashboardController < ApplicationController
    skip_authorization_check
    before_action :authenticate_user!
    before_action :require_admin!

    def index; end

    private

    def require_admin!
      redirect_to root_path, alert: 'Not authorised.' unless current_user.role == User::ADMIN_ROLE
    end
  end
end
