# frozen_string_literal: true

# Admin UI for managing approval matrices.
# Legal can create, edit, and deactivate matrices without engineering.
# Accessible at /admin/approval_matrices (admin users only).
module Admin
  class ApprovalMatricesController < ApplicationController
    skip_authorization_check
    before_action :authenticate_user!
    before_action :require_admin!
    before_action :set_matrix, only: %i[edit update deactivate]

    def index
      @matrices = current_account
                    .caf_approval_matrices
                    .includes(:matrix_audit_events)
                    .order(active: :desc, name: :asc)
    end

    def new
      @matrix = CafApprovalMatrix.new(
        account:         current_account,
        active:          true,
        agreement_types: [],
        stages_config:   default_stages_config
      )
    end

    def create
      @matrix = CafApprovalMatrix.new(matrix_params)
      @matrix.account = current_account

      if @matrix.save
        @matrix.log_audit_event(CafApprovalMatrix::EVENT_CREATED, actor: current_user)
        redirect_to admin_approval_matrices_path,
                    notice: "Matrix \"#{@matrix.name}\" created."
      else
        render :new, status: :unprocessable_entity
      end
    end

    def edit; end

    def update
      original_attrs = @matrix.slice(:name, :agreement_types, :entity_scope,
                                     :value_threshold, :stages_config)

      if @matrix.update(matrix_params)
        @matrix.log_audit_event(
          CafApprovalMatrix::EVENT_UPDATED,
          actor: current_user,
          extra: { previous: original_attrs }
        )
        redirect_to admin_approval_matrices_path,
                    notice: "Matrix \"#{@matrix.name}\" updated."
      else
        render :edit, status: :unprocessable_entity
      end
    end

    def deactivate
      if @matrix.deactivate!(actor: current_user)
        redirect_to admin_approval_matrices_path,
                    notice: "Matrix \"#{@matrix.name}\" deactivated."
      else
        redirect_to admin_approval_matrices_path,
                    alert: "Matrix \"#{@matrix.name}\" is already inactive."
      end
    end

    private

    def require_admin!
      redirect_to root_path, alert: 'Not authorised.' unless current_user.role == User::ADMIN_ROLE
    end

    def set_matrix
      @matrix = current_account.caf_approval_matrices.find(params[:id])
    end

    def matrix_params
      params.require(:caf_approval_matrix).permit(
        :name, :value_threshold, :active,
        agreement_types: [],
        entity_scope:    [],
        stages_config:   [:name, :routing, :strip_internal_on_complete, { required_roles: [] }]
      ).to_h
    end

    def default_stages_config
      [
        {
          'name'                     => 'Internal CAF Approval',
          'routing'                  => 'ordered',
          'required_roles'           => ['BU Head', 'Procurement', 'CLO'],
          'strip_internal_on_complete' => true
        },
        {
          'name'          => 'Counterparty Signing',
          'routing'       => 'parallel',
          'required_roles' => ['counterparty']
        }
      ]
    end
  end
end
