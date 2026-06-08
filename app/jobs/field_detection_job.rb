# frozen_string_literal: true

# IGSIGN — Sprint 2: AI field detection background job.
#
# Strategy:
#   1. Run Templates::DetectFields (ONNX) to get raw field candidates.
#   2. Filter out fields placed on existing text content — the model fires on
#      any text region, including pre-filled party details, addresses, etc.
#      We remove anything that significantly overlaps Pdfium-extracted text.
#   3. Scan every page for signature indicator patterns:
#        • Underscore lines ("_____" ≥ 8 chars) → blank signing line
#        • Labels containing "sign" / "signature" / "initial" within 5% of page above a blank area
#        • "SIGNED at … on" pattern → date field beside the signature
#   4. Assign fields to the correct submitter based on surrounding label context:
#        • Text containing "ignit" / "IG" / "Ignition" / "Sean" / "Donovan" → Stage 1 (IG signer)
#        • Text containing "client" / "counterparty" / party name → Stage 2 (counterparty)
#        • Default → counterparty (Stage 2) for agreement body fields
#
# Silently no-ops when:
#   - ONNX model file is absent
#   - Template already has fields
#   - Any error occurs (never blocks the signing workflow)
class FieldDetectionJob < ApplicationJob
  queue_as :default

  # Fraction of page area that must overlap existing text before we drop a field.
  OVERLAP_THRESHOLD = 0.6

  # Minimum underscore run to count as a blank signature/date line.
  MIN_UNDERSCORE_RUN = 6

  def perform(template_id)
    template = Template.find_by(id: template_id)
    return unless template
    return if template.fields.present?

    unless File.exist?(Templates::ImageToFields::MODEL_PATH)
      Rails.logger.warn("[IGSIGN] FieldDetectionJob: ONNX model not found, skipping #{template_id}")
      return
    end

    submitters  = template.submitters.presence || []
    counterparty = submitters.find { |s| s['name'].to_s.downcase.include?('counterparty') } ||
                   submitters.last
    ig_signer   = submitters.find { |s| s['name'].to_s.match?(/CEO|COO|Bergsma|Signer|Stage.?1/i) } ||
                  (submitters.length > 1 ? submitters[-2] : nil)

    all_fields = []

    template.schema_documents.preload(:blob).each_with_index do |document, _doc_idx|
      begin
        io = StringIO.new(document.download)

        # --- Step 1: ONNX raw detection ---
        raw_detected, = Templates::DetectFields.call(io, attachment: document)

        # --- Step 2: Build text position index from Pdfium ---
        text_runs = build_text_index(document)

        # --- Step 3: Filter out fields that land on existing text ---
        clean_fields = remove_prefilled_fields(raw_detected, text_runs)

        # --- Step 4: Find signature blocks from text patterns ---
        signature_fields = detect_signature_blocks(text_runs, document.uuid, submitters, counterparty, ig_signer)

        # Merge — prefer explicitly detected signatures over ONNX text fields
        merged = merge_fields(clean_fields, signature_fields)

        # --- Step 5: Assign submitters ---
        merged.each do |field|
          field['uuid']           ||= SecureRandom.uuid
          field['preferences']    ||= {}
          field['submitter_uuid'] ||= assign_submitter(field, text_runs, counterparty, ig_signer)
        end

        all_fields.concat(merged)
      rescue StandardError => e
        Rails.logger.warn("[IGSIGN] FieldDetectionJob: error on #{document.uuid}: #{e.message}")
      end
    end

    if all_fields.any?
      template.update_columns(fields: all_fields)
      counts = all_fields.group_by { |f| f['type'] }.transform_values(&:count)
      Rails.logger.info("[IGSIGN] FieldDetectionJob: #{all_fields.count} fields for #{template_id} — #{counts}")
    else
      Rails.logger.info("[IGSIGN] FieldDetectionJob: no fields detected for #{template_id}")
    end
  rescue StandardError => e
    Rails.logger.error("[IGSIGN] FieldDetectionJob error for #{template_id}: #{e.message}")
  end

  private

  # Returns a hash of page_index => [ {text:, x:, y:, w:, h:} ] from Pdfium.
  # Coordinates are fractional (0–1).
  def build_text_index(document)
    index = {}
    runs = DocumentMetadatas.build_text_runs(document)
    runs.each do |page_key, objects|
      page = page_key.to_i
      index[page] = objects.filter_map do |obj|
        text = obj[:text].presence || obj['text'].presence
        next unless text

        # build_text_runs returns x/y in fractional or pixel coords depending on version.
        # We normalise assuming fractional if ≤ 1, else treat as pixels with page size 1.
        x = (obj[:x] || obj['x']).to_f
        y = (obj[:y] || obj['y']).to_f
        w = (obj[:w] || obj['w']).to_f
        h = (obj[:h] || obj['h']).to_f
        { text: text, x: x, y: y, w: w, h: h }
      end
    end
    index
  rescue StandardError
    {}
  end

  # Remove ONNX-detected fields that significantly overlap existing Pdfium text.
  # Pre-filled party details, addresses and registration numbers will be filtered out.
  def remove_prefilled_fields(fields, text_runs)
    fields.reject do |field|
      area = field.dig('areas', 0)
      next false unless area

      page  = area['page'].to_i
      texts = text_runs[page] || []
      next false if texts.empty?

      fx, fy = area['x'].to_f, area['y'].to_f
      fw, fh = area['w'].to_f, area['h'].to_f

      # Check overlap with any substantial text run on this page.
      # We expand the field area slightly to catch nearby text.
      texts.any? do |t|
        tx, ty = t[:x], t[:y]
        tw, th = t[:w], t[:h]

        # Intersection
        ix = [fx, tx].max
        iy = [fy, ty].max
        iw = [[fx + fw, tx + tw].min - ix, 0].max
        ih = [[fy + fh, ty + th].min - iy, 0].max

        intersection = iw * ih
        field_area   = fw * fh
        next false if field_area.zero?

        # If text occupies more than OVERLAP_THRESHOLD of the field area, drop the field.
        t[:text].to_s.length > 3 && (intersection / field_area) > OVERLAP_THRESHOLD
      end
    end
  end

  # Scan text runs for signature indicators and produce signature/date fields.
  def detect_signature_blocks(text_runs, attachment_uuid, submitters, counterparty, ig_signer)
    sig_fields = []

    text_runs.each do |page, texts|
      # Collect underscore lines — these are the blank lines signers write on.
      underscore_lines = texts.select do |t|
        t[:text].to_s.gsub(/\s/, '').match?(/_{#{MIN_UNDERSCORE_RUN},}/)
      end

      underscore_lines.each do |line|
        # Check labels in a window above this line (within 8% of page height).
        window_above = texts.select do |t|
          t[:y] < line[:y] && t[:y] > line[:y] - 0.08
        end
        label_text = window_above.map { |t| t[:text] }.join(' ').downcase

        # Also check same-line text to the left.
        same_line = texts.select do |t|
          (t[:y] - line[:y]).abs < 0.03 && t[:x] < line[:x]
        end
        label_text += ' ' + same_line.map { |t| t[:text] }.join(' ').downcase

        field_type = classify_field_type(label_text)
        next unless field_type

        sig_fields << build_field(
          type:            field_type,
          attachment_uuid: attachment_uuid,
          page:            page,
          x:               line[:x],
          y:               line[:y],
          w:               [line[:w], 0.25].min,
          h:               0.05,
          label_text:      label_text,
          submitters:      submitters,
          counterparty:    counterparty,
          ig_signer:       ig_signer
        )
      end

      # Also scan for "Signature below" / "sign here" label blocks without an
      # underscore line — create a signature placeholder at the blank space below.
      sig_labels = texts.select do |t|
        t[:text].to_s.downcase.match?(/signature\s*(below|here)|sign\s*here/i)
      end

      sig_labels.each do |lbl|
        # Place signature field in the blank space below the label.
        label_text = collect_context(texts, lbl[:x], lbl[:y], lbl[:w], lbl[:h]).downcase
        sig_fields << build_field(
          type:            'signature',
          attachment_uuid: attachment_uuid,
          page:            page,
          x:               lbl[:x],
          y:               lbl[:y] + lbl[:h] + 0.01,
          w:               0.30,
          h:               0.08,
          label_text:      label_text,
          submitters:      submitters,
          counterparty:    counterparty,
          ig_signer:       ig_signer
        )
      end
    end

    sig_fields
  end

  def classify_field_type(label_text)
    return 'signature' if label_text.match?(/sign|initial/i)
    return 'date'      if label_text.match?(/date|dated|on\s+\d|signed.{0,20}on/i)
    return 'text'      if label_text.match?(/name|place|capacity/i)

    nil
  end

  def build_field(type:, attachment_uuid:, page:, x:, y:, w:, h:, label_text:, submitters:, counterparty:, ig_signer:)
    sub_uuid = resolve_party(label_text, counterparty, ig_signer)&.dig('uuid') ||
               counterparty&.dig('uuid') ||
               submitters.last&.dig('uuid')
    {
      'uuid'           => SecureRandom.uuid,
      'submitter_uuid' => sub_uuid,
      'name'           => field_name(type, label_text),
      'type'           => type,
      'required'       => true,
      'preferences'    => (type == 'date' ? { 'format' => 'DD/MM/YYYY' } : {}),
      'areas'          => [{ 'x' => x, 'y' => y, 'w' => w, 'h' => h,
                             'page' => page, 'attachment_uuid' => attachment_uuid }]
    }
  end

  # Determine which submitter a field belongs to based on surrounding text context.
  def resolve_party(label_text, counterparty, ig_signer)
    # Ignition / IG / Sean / Donovan → Stage 1 (IG signer)
    if ig_signer && label_text.match?(/ignit|ignition|for.*on.*behalf.*ignit|sean|donovan|bergsma/i)
      return ig_signer
    end
    # Client / Counterparty / company name → Stage 2
    counterparty
  end

  def assign_submitter(field, text_runs, counterparty, ig_signer)
    area = field.dig('areas', 0)
    return counterparty&.dig('uuid') unless area

    page   = area['page'].to_i
    texts  = text_runs[page] || []
    ctx    = collect_context(texts, area['x'].to_f, area['y'].to_f,
                             area['w'].to_f, area['h'].to_f).downcase

    resolve_party(ctx, counterparty, ig_signer)&.dig('uuid') ||
      counterparty&.dig('uuid')
  end

  # Gather text within an expanded bounding box around (x, y, w, h).
  def collect_context(texts, x, y, w, h)
    pad = 0.10
    texts.select do |t|
      t[:x].between?(x - pad, x + w + pad) &&
        t[:y].between?(y - pad, y + h + pad)
    end.map { |t| t[:text] }.join(' ')
  end

  def field_name(type, label_text)
    snippet = label_text.to_s.gsub(/\W+/, ' ').strip.split.first(4).join(' ').capitalize
    "#{type.capitalize} #{snippet}".strip
  end

  # Merge ONNX-clean fields with explicitly detected signature blocks.
  # If a signature field already covers the same area, drop the ONNX duplicate.
  def merge_fields(onnx_fields, sig_fields)
    result = sig_fields.dup

    onnx_fields.each do |of|
      oa = of.dig('areas', 0)
      next unless oa

      overlap = sig_fields.any? do |sf|
        sa = sf.dig('areas', 0)
        next false unless sa
        next false unless sa['page'] == oa['page']

        (oa['x'] - sa['x']).abs < 0.10 && (oa['y'] - sa['y']).abs < 0.06
      end

      result << of unless overlap
    end

    result
  end
end
