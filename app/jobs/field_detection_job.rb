# frozen_string_literal: true

# IGSIGN — Sprint 2: AI field detection background job.
#
# Runs Templates::DetectFields on each document in the template after upload,
# assigns detected fields to the counterparty submitter by default, and saves
# to template.fields. The user reviews and adjusts in the position wizard step.
#
# Silently no-ops when:
# - The ONNX model file is absent (on-prem server without the model)
# - The template already has fields (user already placed them manually)
# - An error occurs (never blocks the signing workflow)
#
# Do not re-implement field detection — delegates entirely to Templates::DetectFields.
class FieldDetectionJob < ApplicationJob
  queue_as :default

  def perform(template_id)
    template = Template.find_by(id: template_id)
    return unless template
    return if template.fields.present?

    unless File.exist?(Templates::ImageToFields::MODEL_PATH)
      Rails.logger.warn("[IGSIGN] FieldDetectionJob: ONNX model not found, skipping template #{template_id}")
      return
    end

    all_fields = detect_all_fields(template)
    if all_fields.any?
      template.update_columns(fields: all_fields)
      counts = all_fields.group_by { |f| f['type'] }.transform_values(&:count)
      Rails.logger.info("[IGSIGN] FieldDetectionJob: #{all_fields.count} fields for template #{template_id} — #{counts}")
    else
      Rails.logger.info("[IGSIGN] FieldDetectionJob: no fields detected for template #{template_id}")
    end
  rescue StandardError => e
    Rails.logger.error("[IGSIGN] FieldDetectionJob error for template #{template_id}: #{e.message}")
    # Do not re-raise — field detection failure must never block the signing workflow
  end

  private

  def detect_all_fields(template)
    submitters = template.submitters.presence || []
    counterparty = submitters.find { |s| s['name'].to_s.downcase.include?('counterparty') } ||
                   submitters.last

    all_detected = []

    template.schema_documents.preload(:blob).each do |document|
      io = StringIO.new(document.download)
      detected, = Templates::DetectFields.call(io, attachment: document)
      all_detected.concat(detected) if detected.any?
    rescue StandardError => e
      Rails.logger.warn("[IGSIGN] FieldDetectionJob: detection failed for document #{document.uuid}: #{e.message}")
    end

    assign_submitters(all_detected, submitters, counterparty)
  end

  # Assigns detected fields to submitters.
  # Default: all fields go to the counterparty submitter.
  # If an IG submitter is present, signature/date fields on the last page
  # of multi-page docs are heuristically assigned to the IG signer.
  def assign_submitters(fields, submitters, counterparty)
    return [] if fields.empty? || counterparty.nil?

    ig_signer = submitters.find { |s| s['name'].to_s.match?(/CEO|COO|Bergsma/i) }

    fields.map do |field|
      sub_uuid = if ig_signer && signature_on_last_page?(field, fields)
                   ig_signer['uuid']
                 else
                   counterparty['uuid']
                 end

      field.merge(
        'uuid'          => field['uuid'] || SecureRandom.uuid,
        'submitter_uuid' => sub_uuid,
        'preferences'   => field['preferences'] || {}
      )
    end
  end

  # Heuristic: if this field appears on a page that only has a few fields,
  # it's likely the signing page (IG signer's block at the bottom).
  def signature_on_last_page?(field, all_fields)
    return false unless field['type'] == 'signature'

    page = field.dig('areas', 0, 'page').to_i
    max_page = all_fields.flat_map { |f| f['areas'] || [] }.map { |a| a['page'].to_i }.max.to_i
    page == max_page && page.positive?
  end
end
