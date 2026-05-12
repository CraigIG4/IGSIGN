# frozen_string_literal: true

# IGSIGN seed data.
# Safe to re-run — all operations use find_or_create_by / find_or_initialize_by
# so they are fully idempotent.

# ---------------------------------------------------------------------------
# Account
# ---------------------------------------------------------------------------
account = Account.find_or_initialize_by(name: 'Ignition Group')

if account.new_record?
  account.assign_attributes(
    timezone: 'Johannesburg',   # ActiveSupport::TimeZone name for SAST (UTC+2)
    locale:   'en-US'
  )
  account.save!
  puts "Created account: #{account.name}"
else
  puts "Account already exists: #{account.name}"
end

# ---------------------------------------------------------------------------
# Admin user — Craig Doidge
# ---------------------------------------------------------------------------
user = User.find_or_initialize_by(email: 'craig@ignitiongroup.co.za')

if user.new_record?
  user.assign_attributes(
    first_name:    'Craig',
    last_name:     'Doidge',
    password:      'IgSign2026!',
    role:          User::ADMIN_ROLE,
    account:       account,
    confirmed_at:  Time.current   # skip email confirmation on seed
  )
  user.save!
  puts "Created admin user: #{user.email}"
else
  puts "Admin user already exists: #{user.email}"
end

# ---------------------------------------------------------------------------
# IG Entities and People
# ---------------------------------------------------------------------------
# IgSignatories::ENTITIES and IgSignatories::PEOPLE are Ruby constants defined
# in lib/ig_signatories.rb — they require no database seed.
#
# Deactivation is managed via config/ig_signatory_overrides.yml:
#   bundle exec rake "igsign:people:deactivate[email@ignitiongroup.co.za]"
#
# For v2, these will be migrated to managed DB models (IgPerson, IgEntity).
# See docs/todo/v2-people-management.md
puts 'IG entities/people: managed as Ruby constants (no DB seed required)'

# ---------------------------------------------------------------------------
# IGSIGN CAF Template — signing-page PDF + field definitions
# ---------------------------------------------------------------------------
# Creates (or finds) the 'IGSIGN CAF Template' used by CafSubmissionCreator.
# Attaches a minimal blank A4 signing-page PDF and defines:
#   4 submitters : BU Head · Finance Director · CEO · Counterparty
#   3 fields each: signature + full name (text) + date  →  12 fields total
#   Layout       : stacked vertically, left-aligned, bottom 60% of page 1
#
# Idempotent:
#   - PDF is attached only when no document is present yet.
#   - Fields are written only when template.fields is empty.
#   - Submitters are set only together with fields.
# ---------------------------------------------------------------------------

# Generates a minimal valid single-page blank A4 PDF using pure Ruby.
# Byte offsets for the xref table are computed at runtime.
def igsign_blank_a4_pdf
  parts = [
    "%PDF-1.4\n",
    "1 0 obj\n<</Type /Catalog /Pages 2 0 R>>\nendobj\n",
    "2 0 obj\n<</Type /Pages /Kids [3 0 R] /Count 1>>\nendobj\n",
    "3 0 obj\n<</Type /Page /Parent 2 0 R /MediaBox [0 0 595 842]>>\nendobj\n"
  ]
  offsets = []
  pos = 0
  parts.each { |p| offsets << pos; pos += p.bytesize }
  xref_offset = pos
  xref = "xref\n0 4\n0000000000 65535 f \n"
  (1..3).each { |i| xref += format('%010d 00000 n ', offsets[i]) + "\n" }
  trailer = "trailer\n<</Size 4/Root 1 0 R>>\nstartxref\n#{xref_offset}\n%%EOF\n"
  (parts.join + xref + trailer).b
end

caf_account = Account.find_by(name: 'Ignition Group')
caf_user    = User.find_by(email: 'craig@ignitiongroup.co.za')

if caf_account.nil? || caf_user.nil?
  puts 'IGSIGN CAF Template: skipped — account or admin user not found'
else
  caf_template = caf_account.templates.find_or_initialize_by(name: 'IGSIGN CAF Template')

  if caf_template.new_record?
    caf_template.author = caf_user
    caf_template.source = 'native'
    caf_template.save!
    puts 'IGSIGN CAF Template: created'
  else
    puts 'IGSIGN CAF Template: already exists'
  end

  # ── Attach blank signing-page PDF (once only) ──────────────────────────
  unless caf_template.documents.attached?
    pdf_blob = ActiveStorage::Blob.create_and_upload!(
      io:           StringIO.new(igsign_blank_a4_pdf),
      filename:     'caf-signing-page.pdf',
      content_type: 'application/pdf'
    )
    caf_template.documents.attach(pdf_blob)
    pdf_attachment = caf_template.documents.attachments.first

    # Generate page previews so the template builder can display the PDF.
    # Requires pdfium + vips (present in the Docker container).
    begin
      Templates::ProcessDocument.call(pdf_attachment, pdf_attachment.download)
      puts 'IGSIGN CAF Template: signing-page PDF attached and processed'
    rescue StandardError => e
      Rails.logger.warn("[seeds] Templates::ProcessDocument skipped: #{e.message}")
      puts "IGSIGN CAF Template: PDF attached (preview skipped — #{e.message.truncate(80)})"
    end

    caf_template.reload
  end

  # ── Define submitters + fields (once only when fields is empty) ────────
  if caf_template.fields.blank?
    att_uuid = caf_template.documents.attachments.first.uuid

    # Schema must reference the attachment so DocuSeal can render the PDF.
    caf_template.schema = [{ 'attachment_uuid' => att_uuid, 'name' => 'caf-signing-page' }]

    # Signing roles — ordered to match the standard long-form CAF chain.
    caf_submitters = [
      { 'name' => 'BU Head',          'uuid' => SecureRandom.uuid },
      { 'name' => 'Finance Director', 'uuid' => SecureRandom.uuid },
      { 'name' => 'CEO',              'uuid' => SecureRandom.uuid },
      { 'name' => 'Counterparty',     'uuid' => SecureRandom.uuid }
    ]
    caf_template.submitters = caf_submitters

    # Layout constants
    # Coordinates are fractional (0.0–1.0) relative to page width/height.
    # Origin (0,0) = top-left. Four blocks stacked from y=0.40 downward.
    #
    #   Block n starts at y_n = 0.40 + n * 0.145
    #
    #   ┌───────────────────────────────────┐  y_n          (h=0.065)
    #   │  [Signature                      ]│
    #   └───────────────────────────────────┘  y_n+0.065
    #   ┌───────────────────────────────────┐  y_n+0.070    (h=0.030)
    #   │  [Full Name                      ]│
    #   └───────────────────────────────────┘  y_n+0.100
    #   ┌────────────────────┐               y_n+0.105    (h=0.030)
    #   │  [Date            ]│
    #   └────────────────────┘               y_n+0.135
    #                                  gap   y_n+0.145 → next block starts here
    #
    # Block 3 (Counterparty) date ends at 0.40 + 3*0.145 + 0.135 = 0.970 ✓
    x_left  = 0.05
    y_start = 0.40
    y_step  = 0.145

    caf_fields = caf_submitters.each_with_index.flat_map do |sub, idx|
      y  = y_start + (idx * y_step)
      su = sub['uuid']
      [
        {
          'uuid'           => SecureRandom.uuid,
          'submitter_uuid' => su,
          'name'           => "#{sub['name']} Signature",
          'type'           => 'signature',
          'required'       => true,
          'preferences'    => {},
          'areas'          => [{
            'x' => x_left, 'y' => y,         'w' => 0.35, 'h' => 0.065,
            'attachment_uuid' => att_uuid, 'page' => 0
          }]
        },
        {
          'uuid'           => SecureRandom.uuid,
          'submitter_uuid' => su,
          'name'           => "#{sub['name']} Full Name",
          'type'           => 'text',
          'required'       => true,
          'preferences'    => {},
          'areas'          => [{
            'x' => x_left, 'y' => y + 0.070, 'w' => 0.35, 'h' => 0.030,
            'attachment_uuid' => att_uuid, 'page' => 0
          }]
        },
        {
          'uuid'           => SecureRandom.uuid,
          'submitter_uuid' => su,
          'name'           => "#{sub['name']} Date",
          'type'           => 'date',
          'required'       => true,
          'preferences'    => { 'format' => 'DD/MM/YYYY' },
          'areas'          => [{
            'x' => x_left, 'y' => y + 0.105, 'w' => 0.20, 'h' => 0.030,
            'attachment_uuid' => att_uuid, 'page' => 0
          }]
        }
      ]
    end

    caf_template.fields = caf_fields
    caf_template.save!
    puts "IGSIGN CAF Template: #{caf_submitters.length} submitters, " \
         "#{caf_fields.length} fields seeded"
  else
    puts "IGSIGN CAF Template: fields already present " \
         "(#{caf_template.fields.length} fields), skipping"
  end
end
