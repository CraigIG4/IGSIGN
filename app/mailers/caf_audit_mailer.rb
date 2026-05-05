# frozen_string_literal: true
# IGSIGN — Mailer for the final audit bundle delivery.
class CafAuditMailer < ApplicationMailer
  default from: -> { GlobalConfig.dig(:app, :from_email) || 'igsign@ignitiongroup.co.za' }

  # Sends the fully executed document + IGSIGN signing certificate to a recipient.
  def audit_bundle(caf:, to_name:, to_email:)
    @caf           = caf
    @to_name       = to_name
    @requestor     = caf.requestor_name
    @contract_type = caf.caf_type_label
    @entity_name   = caf.entity_name
    @signed_date   = Time.current.strftime('%d %B %Y')

    # Attach the completed contract document if available
    if caf.contract_document.attached?
      attachments[caf.contract_document.blob.filename.to_s] = caf.contract_document.blob.download
    end

    mail(
      to:      "\"#{to_name}\" <#{to_email}>",
      subject: "Signed Agreement — #{caf.contracting_party} — #{@signed_date}",
    )
  end
end
