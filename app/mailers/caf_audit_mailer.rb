# frozen_string_literal: true

# IGSIGN — Mailer for the final audit bundle delivery.
class CafAuditMailer < ApplicationMailer
  # Sends the fully executed document + IGSIGN signing certificate to a recipient.
  #
  # signed_documents: Array of ActiveStorage::Attachment objects representing the
  # counterparty-visible (internal_only: false) documents from the CAF submission.
  # Collected by CafAuditBundleSender#collect_signed_documents, which handles
  # both NDA (dynamically generated PDF on Submission) and non-NDA (uploaded blobs).
  # Defaults to [] so callers that don't provide documents still produce a valid email.
  def audit_bundle(caf:, to_name:, to_email:, signed_documents: [])
    @caf           = caf
    @to_name       = to_name
    @requestor     = caf.requestor_name
    @contract_type = caf.caf_type_label
    @entity_name   = caf.entity_name
    @signed_date   = Time.current.strftime('%d %B %Y')

    # Attach each signed document blob.  Using the blob filename as the attachment
    # key ensures attachments are named sensibly (e.g. nda_agreement_42.pdf).
    Array(signed_documents).each do |doc|
      attachments[doc.blob.filename.to_s] = doc.blob.download
    rescue StandardError => e
      Rails.logger.warn("[CafAuditMailer] Could not attach #{doc&.blob&.filename}: #{e.message}")
    end

    mail(
      to:      "\"#{to_name}\" <#{to_email}>",
      subject: "Signed Agreement — #{caf.contracting_party} — #{@signed_date}"
    )
  end
end
