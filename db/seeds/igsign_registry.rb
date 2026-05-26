# frozen_string_literal: true

# IGSIGN Signatory Registry — canonical seed
#
# Source of truth for all IG entities and the people authorised to sign.
# Data verified against Appendix C of IGSIGN_execution_plan_v5.md (2026-05-26).
#
# IDEMPOTENT: uses find_or_create_by / update! so safe to re-run.
# Run via:
#   bundle exec rails db:seed:igsign_registry
# Or as part of full seed:
#   bundle exec rails db:seed

REGISTERED_ADDRESS = "Quadrant 4, Centenary Building, 30 Meridian Drive\n" \
                     "Umhlanga, KwaZulu-Natal, South Africa".freeze

# ---------------------------------------------------------------------------
# 1. Signatories
# ---------------------------------------------------------------------------

SIGNATORY_DATA = [
  { full_name: 'Sean Bergsma',       email: 'Sean.Bergsma@ignitiongroup.co.za',    role_title: 'Group CEO',                                    seniority: 'Executive' },
  { full_name: 'Donovan Bergsma',    email: 'Donovan.Bergsma@ignitiongroup.co.za', role_title: 'Group COO',                                    seniority: 'Executive' },
  { full_name: 'Craig G. Lawrence',  email: 'Clawre969@ignitiongroup.co.za',       role_title: 'Group CLO',                                    seniority: 'Executive' },
  { full_name: 'Laren Farquharson',  email: 'Laren.Farquharson@ignitiongroup.co.za', role_title: 'Group CFO',                                  seniority: 'Senior Manager' },
  { full_name: 'Callie Baney',       email: 'Callie.Baney@ignitiongroup.co.za',    role_title: 'Group Head of Projects & Procurement',         seniority: 'Senior Manager' },
  { full_name: 'William Talbot',     email: 'William.Talbot@ignitiongroup.co.za',  role_title: 'Business Lead — ITI (NRP and Platforms)',      seniority: 'Senior Manager' },
  { full_name: 'Mark Mitchell',      email: 'Mark.Mitchell@ignitioncx.com',        role_title: 'Chief Client Officer',                         seniority: 'Senior Manager' },
  { full_name: 'Daniel Swart',       email: 'Daniel.Swart@mvnxmobile.co.za',       role_title: 'Executive Head, MVNX',                        seniority: 'Senior Manager' },
  { full_name: 'Matthew Van As',     email: 'Matthew.VanAs@mvnxmobile.co.za',      role_title: 'Finance Director, MVNX',                      seniority: 'Senior Manager' },
  { full_name: 'Ivor vonNielen',     email: 'ivor.vonnielen@uconnect.co.za',        role_title: 'COO, Spot Connect',                          seniority: 'Senior Manager' },
  { full_name: 'Nikola Ramsden',     email: 'Nikola.Ramsden@spot.co.za',            role_title: 'Interim Finance Director (Spot Connect + Spot Money)', seniority: 'Senior Manager' },
  { full_name: 'Siddeek Rahim',      email: 'siddeek.rahim@uconnect.co.za',         role_title: 'CEO, Spot Connect',                          seniority: 'Executive' },
  { full_name: 'Verona Naidoo',      email: 'Verona.Naidoo@ignitiongroup.co.za',   role_title: 'CFO Ignition CX',                              seniority: 'Executive' },
  { full_name: 'Daniel Schauffer',   email: 'Daniel.Schauffer@ignitiongroup.co.za', role_title: 'Senior Finance Manager, Comit (alternate)',  seniority: 'Senior Manager' },
  { full_name: 'Kobus Botha',        email: 'kobus.botha@igfs.co.za',               role_title: 'CEO, IFS',                                   seniority: 'Executive' },
  { full_name: 'Angeline Bennett',   email: 'angeline.bennett@igfs.co.za',          role_title: 'Finance Director, IFS',                      seniority: 'Senior Manager' },
  { full_name: 'Pedro Casimiro',     email: 'Pedro.Casimiro@ignitiongroup.co.za',  role_title: 'Business Lead — Gumtree',                      seniority: 'Senior Manager' },
  { full_name: 'Allan Randell',      email: 'Allan.Randell@spot.co.za',             role_title: 'Head of Product, Spot Money',                seniority: 'Senior Manager' },
  { full_name: 'Richard Swart',      email: 'Richard.Swart@ignitiongroup.co.za',   role_title: 'Executive Head: Telco (pAIments)',             seniority: 'Executive' },
  { full_name: 'Craig DaRocha',      email: 'Craig.DaRocha@ignitiongroup.co.za',   role_title: 'Head of Client Management (OnAir)',            seniority: 'Executive' }
].freeze

SIGNATORY_DATA.each do |attrs|
  sig = IgSignatory.find_or_initialize_by(email: attrs[:email])
  sig.assign_attributes(attrs)
  sig.save!
  puts "  Signatory: #{sig.full_name} (#{sig.email})"
end

puts "Seeded #{SIGNATORY_DATA.length} signatories"

# ---------------------------------------------------------------------------
# Helper to look up a signatory by email (raises if not found — fail fast)
# ---------------------------------------------------------------------------
def sig(email)
  IgSignatory.find_by!(email: email)
rescue ActiveRecord::RecordNotFound
  raise "Signatory not found: #{email} — seed order error?"
end

# ---------------------------------------------------------------------------
# 2. Entities and their signing chains
# ---------------------------------------------------------------------------
# Format:
#   entity_data:  attrs for IgEntity
#   signatories:  array of [email, position, notes?] for IgEntitySignatory
#
# Global positions — assigned to EVERY entity:
#   group_clo  → Craig G. Lawrence
#   group_cfo  → Laren Farquharson    (also bu_cfo for ITI — see note ¹ in plan)
#   procurement → Callie Baney       (included when is_supplier: true — always seeded)
# ---------------------------------------------------------------------------

ENTITY_DATA = [
  {
    entity: { key: 'iti', name: 'Ignition Telecoms Investments (Pty) Ltd', display_name: 'ITI',
              registration_number: '2010/016551/07', registered_address: REGISTERED_ADDRESS },
    signatories: [
      # ¹ Laren is both ITI's BU CFO and Group CFO for all entities.
      # She is seeded as bu_cfo for ITI; the group_cfo row is added in the global pass below.
      ['William.Talbot@ignitiongroup.co.za',     'bu_head',    nil],
      ['Laren.Farquharson@ignitiongroup.co.za',  'bu_cfo',     'Also Group CFO; appears in Stage 0 for all entities'],
      ['Sean.Bergsma@ignitiongroup.co.za',       'group_signer', nil],
      ['Donovan.Bergsma@ignitiongroup.co.za',    'group_signer_alt', 'Operational/intra-co agreements']
    ]
  },
  {
    entity: { key: 'comit', name: 'Comit Technologies (Pty) Ltd', display_name: 'Comit',
              registration_number: '2011/005082/07', registered_address: REGISTERED_ADDRESS },
    signatories: [
      ['Mark.Mitchell@ignitioncx.com',              'bu_head',          nil],
      ['Verona.Naidoo@ignitiongroup.co.za',         'bu_cfo',           nil],
      ['Daniel.Schauffer@ignitiongroup.co.za',      'bu_cfo_alternate', nil],
      ['Sean.Bergsma@ignitiongroup.co.za',          'group_signer',     nil]
    ]
  },
  {
    entity: { key: 'mvnx', name: 'MVNX (Pty) Ltd', display_name: 'MVNX',
              registration_number: '2012/032479/07',
              registered_address: "Quadrant 4, Centenary Building, 30 Meridian Drive\nUmhlanga, 4319\nKwaZulu-Natal, South Africa" },
    signatories: [
      ['Daniel.Swart@mvnxmobile.co.za',   'bu_head',      nil],
      ['Matthew.VanAs@mvnxmobile.co.za',  'bu_cfo',       nil],
      ['Sean.Bergsma@ignitiongroup.co.za', 'group_signer', nil]
    ]
  },
  {
    entity: { key: 'spot_connect', name: 'UConnect Mobile (Pty) Ltd (trading as Spot Connect)',
              display_name: 'Spot Connect', registration_number: '2021/784475/07',
              registered_address: REGISTERED_ADDRESS },
    signatories: [
      ['ivor.vonnielen@uconnect.co.za',             'bu_head',          nil],
      ['Nikola.Ramsden@spot.co.za',                 'bu_cfo',           nil],
      # Stage 1 is two sub-stages: Siddeek signs first, then Sean (Stage 2 handles routing)
      ['siddeek.rahim@uconnect.co.za',              'group_signer',     'Stage 1 first sub-stage'],
      ['Sean.Bergsma@ignitiongroup.co.za',          'group_signer_alt', 'Stage 1 second sub-stage (after Siddeek)']
    ]
  },
  {
    entity: { key: 'ignition_digital', name: 'Ignition Digital LLC', display_name: 'Ignition Digital',
              registration_number: nil, registered_address: REGISTERED_ADDRESS },
    signatories: [
      ['Mark.Mitchell@ignitioncx.com',             'bu_head',      nil],
      ['Verona.Naidoo@ignitiongroup.co.za',        'bu_cfo',       nil],
      ['Donovan.Bergsma@ignitiongroup.co.za',      'group_signer', nil]
    ]
  },
  {
    entity: { key: 'ignition_cx_us', name: 'Ignition CX (US)', display_name: 'Ignition CX (US)',
              registration_number: nil, registered_address: REGISTERED_ADDRESS },
    signatories: [
      ['Mark.Mitchell@ignitioncx.com',             'bu_head',      nil],
      ['Verona.Naidoo@ignitiongroup.co.za',        'bu_cfo',       nil],
      ['Donovan.Bergsma@ignitiongroup.co.za',      'group_signer', nil]
    ]
  },
  {
    # ² Kobus is both BU Head and Stage 1 signer. Sean is Stage 0 approver only (not Stage 1).
    entity: { key: 'ifs', name: 'Ignition Financial Services (Pty) Ltd (IFS, Viva Cover, Viva Life)',
              display_name: 'IFS', registration_number: nil, registered_address: REGISTERED_ADDRESS },
    signatories: [
      ['kobus.botha@igfs.co.za',                   'bu_head',      'Also the Stage 1 signer'],
      ['angeline.bennett@igfs.co.za',              'bu_cfo',       nil],
      ['kobus.botha@igfs.co.za',                   'group_signer', 'IFS exception: Kobus signs Stage 1'],
      ['Sean.Bergsma@ignitiongroup.co.za',         'approver_only', 'Stage 0 approver; does NOT sign Stage 1 for IFS']
    ]
  },
  {
    entity: { key: 'gumtree', name: 'Gumtree South Africa (Pty) Ltd', display_name: 'Gumtree',
              registration_number: nil, registered_address: REGISTERED_ADDRESS },
    signatories: [
      ['Pedro.Casimiro@ignitiongroup.co.za',       'bu_head',      nil],
      # BU CFO for Gumtree is TBC — to be confirmed and added via admin UI
      ['Donovan.Bergsma@ignitiongroup.co.za',      'group_signer', nil]
    ]
  },
  {
    entity: { key: 'spot_money', name: 'Spot Money (Pty) Ltd', display_name: 'Spot Money',
              registration_number: nil, registered_address: REGISTERED_ADDRESS },
    signatories: [
      ['Allan.Randell@spot.co.za',                 'bu_head',      nil],
      ['Nikola.Ramsden@spot.co.za',                'bu_cfo',       'Shared with Spot Connect'],
      ['Sean.Bergsma@ignitiongroup.co.za',         'group_signer', nil]
    ]
  }
].freeze

# ---------------------------------------------------------------------------
# Global signatories added to EVERY entity
# ---------------------------------------------------------------------------
GLOBAL_POSITIONS = [
  ['Clawre969@ignitiongroup.co.za',         'group_clo',   'Group CLO — approves Stage 0 for all entities'],
  ['Laren.Farquharson@ignitiongroup.co.za', 'group_cfo',   'Group CFO — approves Stage 0 for all entities'],
  ['Callie.Baney@ignitiongroup.co.za',      'procurement', 'Added to Stage 0 when agreement is supplier-side']
].freeze

ENTITY_DATA.each do |record|
  entity = IgEntity.find_or_initialize_by(key: record[:entity][:key])
  entity.assign_attributes(record[:entity])
  entity.save!
  puts "  Entity: #{entity.name} (#{entity.key})"

  # Entity-specific signatories
  record[:signatories].each do |email_addr, position, notes|
    signatory = sig(email_addr)
    join = IgEntitySignatory.find_or_initialize_by(
      ig_entity:    entity,
      ig_signatory: signatory,
      position:     position
    )
    join.notes  = notes
    join.active = true
    join.save!
  end

  # Global signatories (CLO, CFO, Procurement) — skip if already added above
  GLOBAL_POSITIONS.each do |email_addr, position, notes|
    signatory = sig(email_addr)
    join = IgEntitySignatory.find_or_initialize_by(
      ig_entity:    entity,
      ig_signatory: signatory,
      position:     position
    )
    join.notes  ||= notes
    join.active   = true
    join.save!
  end
end

puts "Seeded #{ENTITY_DATA.length} entities with signing chains"
puts "Registry complete: #{IgEntitySignatory.count} entity-signatory assignments"
