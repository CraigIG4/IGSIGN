# frozen_string_literal: true

# IGSIGN — Generates the actual NDA agreement PDF from an ERB template.
#
# This is distinct from CafPdfGenerator which produces the internal
# NDA *approval form*.  This service produces the legally-binding NDA
# document that both IG and the counterparty ultimately sign.
#
# The template at app/views/cafs/nda_agreement.html.erb is populated with
# dynamic party details (IG entity, counterparty) and the Purpose from the
# workflow, then converted to PDF via LibreOffice.
#
# Usage:
#   pdf_path = NdaAgreementGenerator.new(caf_workflow).generate
#   # => "/rails_root/tmp/nda_agreement_42_a1b2c3d4.pdf"
#   # Caller is responsible for deleting the file after use.
class NdaAgreementGenerator
  SOFFICE  = CafPdfGenerator::SOFFICE
  TEMPLATE = Rails.root.join('app/views/cafs/nda_agreement.html.erb').freeze

  def initialize(agreement)
    @agreement = agreement
  end

  def generate
    html_path = nil
    html_path = write_html(render_html)
    convert_to_pdf(html_path)
  ensure
    File.delete(html_path) if html_path && File.exist?(html_path)
  end

  private

  def nda_data
    entity_key = @agreement.entity.to_s
    entity     = IgSignatories.entity_details(entity_key)
    company    = @agreement.company

    {
      agreement_id:             @agreement.id,
      date_prepared:            Time.current.strftime('%d %B %Y'),
      # IG entity
      entity_name:              entity&.name || @agreement.entity.to_s.humanize,
      entity_registration:      entity&.registration_number || 'To be verified',
      entity_address:           entity&.registered_address || IgSignatories::REGISTERED_ADDRESS,
      # Counterparty
      counterparty_company:     (@agreement.contracting_party.presence || company&.name).to_s,
      counterparty_registration: company&.registration_number.to_s,
      counterparty_address:     company&.address.to_s,
      counterparty_contact_name: @agreement.counterparty_name.to_s,
      counterparty_email:       @agreement.counterparty_email.to_s,
      # Agreement details
      agreement_term:           @agreement.agreement_term.presence || '3 (three) years',
      agreement_purpose:        @agreement.agreement_purpose.to_s,
      mandate_description:      @agreement.mandate_description.to_s
    }
  end

  def render_html
    raise "NDA agreement template not found: #{TEMPLATE}" unless File.exist?(TEMPLATE)

    ctx = ERBContext.new(nda_data)
    ERB.new(File.read(TEMPLATE)).result(ctx.template_binding)
  end

  def write_html(html)
    path = Rails.root.join("tmp/nda_agreement_#{@agreement.id}_#{SecureRandom.hex(4)}.html").to_s
    File.write(path, html)
    path
  end

  def convert_to_pdf(html_path)
    out_dir  = Rails.root.join('tmp').to_s
    pdf_path = File.join(out_dir, "#{File.basename(html_path, '.html')}.pdf")
    success  = system(SOFFICE, '--headless', '--convert-to', 'pdf', '--outdir', out_dir, html_path)
    raise 'LibreOffice PDF conversion failed for NDA agreement' unless success && File.exist?(pdf_path)

    pdf_path
  end

  class ERBContext
    def initialize(caf_hash)
      @caf = caf_hash
    end

    def template_binding
      binding
    end
  end
end
