# frozen_string_literal: true

# IGSIGN — CAF PDF generation via Grover (headless Chrome).
#
# Replaces the previous LibreOffice conversion — Chrome renders the HTML exactly
# as a browser would, supporting DM Sans, Tailwind-compatible CSS, and proper
# page-break behaviour.
#
# generate → returns binary PDF String (not a file path).
# Callers must use StringIO.new(pdf_data) for ActiveStorage or send_data directly.
#
# LibreOffice is retained in the Docker image for DOCX→PDF conversion
# (CafSubmissionCreator#convert_docx). Do not remove it from the Dockerfile.
class CafPdfGenerator
  SOFFICE = '/usr/bin/soffice'
  TEMPLATES = {
    'long_form'  => Rails.root.join('app/views/cafs/long_form.html.erb'),
    'short_form' => Rails.root.join('app/views/cafs/short_form.html.erb'),
    'nda'        => Rails.root.join('app/views/cafs/nda.html.erb')
  }.freeze

  def initialize(agreement)
    @agreement = agreement
  end

  # Returns binary PDF data.
  def generate
    Grover.new(
      render_html,
      format:           'A4',
      print_background: true,
      margin:           { top: '15mm', bottom: '15mm', left: '15mm', right: '15mm' }
    ).to_pdf
  end

  private

  # rubocop:disable Metrics/MethodLength, Metrics/AbcSize
  def caf_data
    entity_key = @agreement.entity.to_s
    entity     = IgSignatories.entity_details(entity_key)
    chain      = IgSignatories.chain_for(entity_key, @agreement.caf_type)
    all_stage1 = chain[:stage1] || []

    group_positions = %w[group_clo group_cfo group_ceo group_coo group_signer group_signer_alt procurement]
    bu_heads = all_stage1.reject { |p| group_positions.include?(p[:position].to_s) }

    find_by_pos = ->(pos) { all_stage1.find { |p| p[:position].to_s == pos } || {} }
    group_clo   = find_by_pos.call('group_clo')
    group_cfo   = find_by_pos.call('group_cfo')
    group_ceo   = [find_by_pos.call('group_signer'), find_by_pos.call('group_ceo')].find(&:any?) || {}
    group_coo   = [find_by_pos.call('group_coo'), find_by_pos.call('group_signer_alt')].find(&:any?) || {}
    procurement = find_by_pos.call('procurement')

    prov = @agreement.parsed_data_provenance.presence || {}

    {
      # ── Identity ────────────────────────────────────────────────────────
      agreement_id:              @agreement.id,
      agreement_type_label:      @agreement.agreement_type_label,
      caf_type:                  @agreement.caf_type,
      commercial_relationship:   @agreement.commercial_relationship.to_s.capitalize,
      date_prepared:             Time.current.strftime('%d %B %Y'),

      # ── Entity ──────────────────────────────────────────────────────────
      entity_name:               entity&.name || @agreement.entity.to_s.humanize,
      entity_registration:       entity&.registration_number || 'To be verified',
      entity_address:            entity&.registered_address || IgSignatories::REGISTERED_ADDRESS,

      # ── Counterparty ────────────────────────────────────────────────────
      counterparty_company:      (@agreement.contracting_party.presence || @agreement.company&.name).to_s,
      counterparty_registration: @agreement.company&.registration_number.to_s,
      counterparty_address:      @agreement.company&.address.to_s,
      counterparty_contact_name: @agreement.counterparty_name.to_s,
      counterparty_email:        @agreement.counterparty_email.to_s,

      # ── Requestor ───────────────────────────────────────────────────────
      requestor_name:            @agreement.requestor_name.presence || 'To be completed',
      requestor_email:           @agreement.requestor_email.to_s,
      document_name:             @agreement.template&.name.to_s,

      # ── Sprint 0: AI-extracted summary and term fields ───────────────────
      high_level_summary:        @agreement.high_level_summary.to_s,
      mandate_description:       @agreement.mandate_description.to_s,
      agreement_purpose:         @agreement.agreement_purpose.to_s,
      effective_date:            @agreement.effective_date&.strftime('%d %B %Y').to_s,
      expiry_date:               @agreement.expiry_date&.strftime('%d %B %Y').to_s,
      period:                    @agreement.agreement_term.to_s,
      auto_renewal:              @agreement.auto_renewal,
      notice_period_days:        @agreement.notice_period_days,

      # ── Cancellation ────────────────────────────────────────────────────
      cancellation_for_convenience: @agreement.cancellation_for_convenience.to_s,
      cancellation_breach:          @agreement.cancellation_breach.to_s,

      # ── Limitation of Liability ─────────────────────────────────────────
      liability_exclusion_indirect: @agreement.liability_exclusion_indirect.to_s,
      liability_cap:                @agreement.liability_cap.to_s,

      # ── Key Provisions ──────────────────────────────────────────────────
      data_protection_clause:    @agreement.data_protection_clause.to_s,
      change_of_control:         @agreement.change_of_control.to_s,
      ip_ownership:              @agreement.ip_ownership.to_s,
      governing_law:             @agreement.governing_law.to_s,

      # ── Commercial ──────────────────────────────────────────────────────
      agreement_value:           @agreement.agreement_value.to_s,
      currency:                  @agreement.currency.presence || 'ZAR',
      minimum_spend:             @agreement.minimum_spend.to_s,
      pricing_structure:         @agreement.pricing_structure.to_s,
      payment_terms_days:        @agreement.payment_terms_days,
      payment_terms:             @agreement.payment_terms.to_s,
      payment_metric_type:       @agreement.payment_metric_type.to_s,
      seat_cost:                 @agreement.seat_cost.to_s,
      training_cost:             @agreement.training_cost.to_s,
      number_of_seats:           @agreement.number_of_seats.to_s,

      # ── Commercial Continued ─────────────────────────────────────────────
      price_escalation:          @agreement.price_escalation.to_s,
      exclusivity:               @agreement.exclusivity.to_s,
      assignment:                @agreement.assignment.to_s,

      # ── Enforcement ─────────────────────────────────────────────────────
      dispute_resolution:        @agreement.dispute_resolution.to_s,
      sla_penalties:             @agreement.sla_penalties.to_s,

      # ── Operational Rights ───────────────────────────────────────────────
      renewal_options:           @agreement.renewal_options.to_s,
      audit_rights:              @agreement.audit_rights.to_s,
      subcontracting:            @agreement.subcontracting.to_s,

      # ── Risks ───────────────────────────────────────────────────────────
      key_risks:                 @agreement.key_risks.to_s,

      # ── Addendum (conditional) ──────────────────────────────────────────
      change_in_addendum:        @agreement.change_in_addendum.to_s,

      # ── Provenance badges ────────────────────────────────────────────────
      parsed_data_provenance:    prov,

      # ── Signatories ──────────────────────────────────────────────────────
      bu_heads:                  bu_heads,
      group_clo_name:            group_clo[:name]  || 'Craig G. Lawrence',
      group_clo_title:           group_clo[:title] || 'Group CLO',
      group_cfo_name:            group_cfo[:name]  || 'Laren Farquharson',
      group_cfo_title:           group_cfo[:title] || 'Group CFO',
      group_ceo_name:            group_ceo[:name]  || 'Sean Bergsma',
      group_ceo_title:           group_ceo[:title] || 'Group CEO',
      group_coo_name:            group_coo[:name]  || 'Donovan Bergsma',
      group_coo_title:           group_coo[:title] || 'Group COO',
      procurement_name:          procurement[:name].to_s,
      procurement_title:         procurement[:title].to_s,
      bu_finance_name:           group_cfo[:name]  || 'Laren Farquharson',
      bu_finance_title:          group_cfo[:title] || 'Group Finance Director',
      signing_rows:              all_stage1.reject { |p| p[:name].blank? }.map do |p|
        { name: p[:name].to_s, title: p[:title].to_s, position: p[:position].to_s }
      end
    }
  end
  # rubocop:enable Metrics/MethodLength, Metrics/AbcSize

  def render_html
    tpl_path = TEMPLATES[@agreement.caf_type] || TEMPLATES['long_form']
    raise "CAF template not found: #{tpl_path}" unless File.exist?(tpl_path)

    ctx = ERBContext.new(caf_data)
    ERB.new(File.read(tpl_path)).result(ctx.template_binding)
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
