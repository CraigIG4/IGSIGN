# frozen_string_literal: true
# IGSIGN — Counterparty company directory
class CompaniesController < ApplicationController
  before_action :authenticate_user!
  before_action :set_company, only: %i[show edit update]

  def index
    @companies = current_account.companies.alphabetical
    @companies = @companies.search(params[:q]) if params[:q].present?
    @total     = current_account.companies.count
  end

  def new
    @company = Company.new
  end

  def create
    @company         = Company.new(company_params)
    @company.account = current_account

    if @company.save
      redirect_to companies_path, notice: "#{@company.name} added to your directory."
    else
      render :new, status: :unprocessable_entity
    end
  end

  def show
    @agreements = @company.caf_workflows.recent.limit(10)
  end

  def edit; end

  def update
    if @company.update(company_params)
      redirect_to company_path(@company), notice: 'Counterparty updated.'
    else
      render :edit, status: :unprocessable_entity
    end
  end

  private

  def set_company
    @company = current_account.companies.find(params[:id])
  end

  def company_params
    params.require(:company).permit(
      :name, :registration_number, :domain,
      :primary_contact_name, :primary_contact_email,
      :address, :country
    )
  end
end
