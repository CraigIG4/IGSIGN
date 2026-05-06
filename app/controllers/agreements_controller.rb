# frozen_string_literal: true
# IGSIGN — Agreement Wizard: Details → Upload → Review → Send
class AgreementsController < ApplicationController
  before_action :authenticate_user!
  before_action :set_agreement, only: %i[show upload process_upload review send_agreement]

  # ── Index ──────────────────────────────────────────────────────────────────

  def index
    scope = current_account.caf_workflows.includes(:company, :created_by_user).recent

    if (sf = params[:status].to_s.strip).present? && CafWorkflow::STATUSES.include?(sf)
      scope = scope.where(status: sf)
    end

    @agreements = scope
    @stats = {
      total:    current_account.caf_workflows.count,
      draft:    current_account.caf_workflows.draft.count,
      active:   current_account.caf_workflows.active.count,
      complete: current_account.caf_workflows.complete.count
    }
  end

  # ── Step 1 — Details ───────────────────────────────────────────────────────

  def new
    @agreement = CafWorkflow.new(
      requestor_name:  current_user.name,
      requestor_email: current_user.email
    )
    @companies = current_account.companies.alphabetical
    @step = 1
  end

  def create
    @agreement             = CafWorkflow.new(agreement_params)
    @agreement.account     = current_account
    @agreement.created_by_user = current_user
    @agreement.status      = 'draft'

    # Inline company creation when user types a new name
    if params[:new_company_name].present?
      co = current_account.companies.find_or_initialize_by(name: params[:new_company_name].strip)
      co.assign_attributes(
        primary_contact_name:  params[:new_company_contact_name].to_s.strip,
        primary_contact_email: params[:new_company_contact_email].to_s.strip,
        domain:                params[:new_company_domain].to_s.strip
      )
      co.save
      @agreement.company = co
    end

    # Auto-fill counterparty fields from company record
    if (co = @agreement.company)
      @agreement.contracting_party  = co.name if @agreement.contracting_party.blank?
      @agreement.counterparty_name  = co.primary_contact_name  if @agreement.counterparty_name.blank?
      @agreement.counterparty_email = co.primary_contact_email if @agreement.counterparty_email.blank?
    end

    @agreement.auto_assign_signatories!

    if @agreement.save
      redirect_to upload_agreement_path(@agreement)
    else
      @companies = current_account.companies.alphabetical
      @step = 1
      render :new, status: :unprocessable_entity
    end
  end

  # ── Step 2 — Upload ────────────────────────────────────────────────────────

  def upload
    @step = 2
  end

  def process_upload
    file = params[:file]
    if file.blank?
      return redirect_to upload_agreement_path(@agreement),
                         alert: 'Please choose a document to upload.'
    end

    template = Template.new(
      account: current_account,
      author:  current_user,
      name:    "#{@agreement.agreement_type_label} — #{@agreement.contracting_party.presence || 'Agreement'}"
    )

    unless template.save
      return redirect_to upload_agreement_path(@agreement),
                         alert: 'Could not initialise document record.'
    end

    begin
      Templates::CreateAttachments.call(template, { files: [file] }, extract_fields: true)
      @agreement.update!(template_id: template.id)
      redirect_to review_agreement_path(@agreement)
    rescue => e
      template.destroy
      Rails.logger.error "[IGSIGN] Upload failed agreement=#{@agreement.id}: #{e.message}"
      redirect_to upload_agreement_path(@agreement),
                  alert: "Upload failed: #{e.message.to_s.truncate(200)}"
    end
  end

  # ── Step 3 — Review ────────────────────────────────────────────────────────

  def review
    @step         = 3
    @signatories  = @agreement.signatories || []
    @template_doc = @agreement.template
  end

  # ── Send ───────────────────────────────────────────────────────────────────

  def send_agreement
    unless @agreement.draft?
      return redirect_to agreement_path(@agreement),
                         alert: 'This agreement has already been submitted.'
    end

    result = CafSubmissionCreator.new(@agreement, current_user).call

    if result[:success]
      @agreement.update!(status: 'pending_ig', caf_submission: result[:submission])
      @agreement.company&.sync_agreements_count!
      redirect_to agreement_path(@agreement),
                  notice: 'Agreement submitted. Internal signatories have been notified.'
    else
      redirect_to review_agreement_path(@agreement),
                  alert: "Could not send: #{result[:error]}"
    end
  end

  # ── Show ───────────────────────────────────────────────────────────────────

  def show
    @signatories = @agreement.signatories || []
  end

  # ── AJAX company search ────────────────────────────────────────────────────

  def search_companies
    q         = params[:q].to_s.strip
    companies = q.length >= 1 ? current_account.companies.search(q).limit(8)
                               : current_account.companies.alphabetical.limit(8)

    render json: companies.map { |c|
      {
        id:            c.id,
        name:          c.name,
        contact_name:  c.primary_contact_name,
        contact_email: c.primary_contact_email,
        domain:        c.domain,
        count:         c.agreements_count
      }
    }
  end

  private

  def set_agreement
    @agreement = current_account.caf_workflows.find(params[:id])
  rescue ActiveRecord::RecordNotFound
    redirect_to agreements_path, alert: 'Agreement not found.'
  end

  def agreement_params
    params.require(:agreement).permit(
      :agreement_type, :entity, :ignition_company,
      :contracting_party, :counterparty_name, :counterparty_email,
      :company_id, :requestor_name, :requestor_email,
      :high_level_summary, :mandate_description
    )
  end
end
