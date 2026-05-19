# frozen_string_literal: true

class TemplatesShareLinkController < ApplicationController
  load_and_authorize_resource :template

  def show; end

  def create
    authorize!(:update, @template)

    @template.update!(template_params)

    if params[:redir].present?
      # allow_other_host: false prevents open-redirect to external domains.
      # Rails 8 enforces this by default but being explicit here documents the
      # intent and guards against accidental config changes.
      redirect_to params[:redir], allow_other_host: false
    else
      head :ok
    end
  end

  private

  def template_params
    params.require(:template).permit(:shared_link)
  end
end
