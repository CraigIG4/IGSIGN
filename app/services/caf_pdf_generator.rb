# frozen_string_literal: true

class CafPdfGenerator
  SOFFICE = '/usr/bin/soffice'
  TEMPLATES = {
    'long_form' => Rails.root.join('app/views/cafs/long_form.html.erb'),
    'short_form' => Rails.root.join('app/views/cafs/short_form.html.erb'),
    'nda' => Rails.root.join('app/views/cafs/nda.html.erb')
  }.freeze

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

  def caf_data
    entity_key = @agreement.entity.to_sym
    entity     = IgSignatories::ENTITIES[entity_key] || {}
    chain      = IgSignatories.chain_for(@agreement.caf_type, entity_key)
    finance    = IgSignatories.person(:laren_farquharson) || {}
    group_keys = %i[laren_farquharson sean_bergsma donovan_bergsma]
    bu_heads   = chain[:stage1].reject { |p| group_keys.include?(p[:key]) }
    {
      agreement_id: @agreement.id,
      agreement_type_label: @agreement.agreement_type_label,
      caf_type: @agreement.caf_type,
      date_prepared: Time.current.strftime('%d %B %Y'),
      entity_name: entity[:name] || @agreement.entity.to_s.humanize,
      entity_registration: entity[:registration] || 'To be verified',
      entity_address: entity[:address] || IgSignatories::REGISTERED_ADDRESS,
      counterparty_company: (@agreement.contracting_party.presence || @agreement.company&.name).to_s,
      counterparty_registration: @agreement.company&.registration_number.to_s,
      counterparty_address: @agreement.company&.address.to_s,
      counterparty_contact_name: @agreement.counterparty_name.to_s,
      counterparty_email: @agreement.counterparty_email.to_s,
      mandate_description: @agreement.mandate_description.to_s,
      agreement_purpose: @agreement.agreement_purpose.to_s,
      agreement_value:   @agreement.agreement_value.to_s,
      agreement_term:    @agreement.agreement_term.to_s,
      payment_terms:     @agreement.payment_terms.to_s,
      key_risks:         @agreement.key_risks.to_s,
      document_name:     @agreement.template&.name.to_s,
      requestor_name: @agreement.requestor_name.presence || 'To be completed',
      requestor_email: @agreement.requestor_email.to_s,
      bu_heads: bu_heads,
      bu_finance_name: finance[:name] || 'Laren Farquharson',
      bu_finance_title: finance[:title] || 'Group Finance Director'
    }
  end

  def render_html
    tpl_path = TEMPLATES[@agreement.caf_type] || TEMPLATES['long_form']
    raise "CAF template not found: #{tpl_path}" unless File.exist?(tpl_path)

    ctx = ERBContext.new(caf_data)
    ERB.new(File.read(tpl_path)).result(ctx.template_binding)
  end

  def write_html(html)
    path = Rails.root.join("tmp/caf_#{@agreement.id}_#{SecureRandom.hex(4)}.html").to_s
    File.write(path, html)
    path
  end

  def convert_to_pdf(html_path)
    out_dir  = Rails.root.join('tmp').to_s
    pdf_path = File.join(out_dir, "#{File.basename(html_path, '.html')}.pdf")
    success  = system(SOFFICE, '--headless', '--convert-to', 'pdf', '--outdir', out_dir, html_path)
    raise 'LibreOffice PDF conversion failed' unless success && File.exist?(pdf_path)

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
