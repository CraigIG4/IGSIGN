# frozen_string_literal: true

# Sprint 5 — Contracts Dashboard (Pillar 5).
# Landing page for Legal Ops — live contracts register with risk indicators,
# expiry alerts, data completeness scores, and management navigation.
#
# All queries use indexed native columns, never jsonb. Fast at scale.
module LegalOps
  class DashboardController < ApplicationController
    skip_authorization_check
    before_action :authenticate_user!
    before_action :require_admin!

    def index
      base = current_account.caf_workflows
                             .where.not(status: 'cancelled')

      # ── Filters ──────────────────────────────────────────────────────────
      @filter_entity       = params[:entity].presence
      @filter_type         = params[:agreement_type].presence
      @filter_relationship = params[:relationship].presence
      @filter_status       = params[:status].presence
      @filter_expiry       = params[:expiry].presence    # 'soon' | 'overdue' | 'none'
      @q                   = params[:q].to_s.strip

      scope = base
      scope = scope.where(entity: @filter_entity)                        if @filter_entity
      scope = scope.where(agreement_type: @filter_type)                  if @filter_type
      scope = scope.commercial_customer                                   if @filter_relationship == 'customer'
      scope = scope.commercial_supplier                                   if @filter_relationship == 'supplier'
      scope = scope.where(status: @filter_status)                        if @filter_status

      scope = case @filter_expiry
              when 'soon'    then scope.where(expiry_date: Date.today..90.days.from_now)
              when 'overdue' then scope.where(expiry_date: ..Date.yesterday).where.not(status: 'complete')
              when 'none'    then scope.where(expiry_date: nil)
              else scope
              end

      if @q.present?
        scope = scope.where(
          'contracting_party ILIKE :q OR counterparty_name ILIKE :q',
          q: "%#{@q}%"
        )
      end

      # ── Stats (always from full base, ignoring filters) ─────────────────
      today = Date.today
      @stats = {
        total_active:        base.where.not(status: %w[complete draft]).count,
        expiring_30:         base.where(expiry_date: today..30.days.from_now).count,
        expiring_90:         base.where(expiry_date: today..90.days.from_now).count,
        auto_renewal_at_risk: base.where(auto_renewal: true)
                                  .where(expiry_date: today..90.days.from_now).count,
        complete:            base.where(status: 'complete').count,
        draft:               base.where(status: 'draft').count
      }

      # ── Table ────────────────────────────────────────────────────────────
      @workflows = scope
                     .includes(:company, :created_by_user)
                     .order(Arel.sql(
                       "CASE WHEN expiry_date IS NULL THEN 1 ELSE 0 END, expiry_date ASC NULLS LAST, created_at DESC"
                     ))

      # ── Filter options ───────────────────────────────────────────────────
      @entities        = IgEntity.active.ordered
      @agreement_types = CafWorkflow::AGREEMENT_TYPES
      @statuses        = CafWorkflow::STATUSES.reject { |s| s == 'cancelled' }
    end

    private

    def require_admin!
      redirect_to root_path, alert: 'Not authorised.' unless current_user.role == User::ADMIN_ROLE
    end
  end
end
