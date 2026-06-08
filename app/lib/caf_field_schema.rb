# frozen_string_literal: true

# Defines every field that flows from contract extraction through to the dashboard.
# type:          determines input type in manual fallback form and JSON output format
# dashboard:     true means this field appears on the contracts dashboard
# caf_column:    the caf_workflows column this field maps to (nil = jsonb only)
# prompt_guide:  the per-field extraction instruction embedded in the LLM prompt
#                CRITICAL: every guide must say SUMMARIZE not copy. See sprint plan methodology.
#
# "Not Included" Rule: for all legal/commercial provision fields, if the contract does not
# contain the provision, return "Not Included" — not null. Null means extraction did not run
# or field could not be determined. "Not Included" means extraction ran and provision is absent.
module CafFieldSchema
  FIELDS = [
    # ── IDENTITY ─────────────────────────────────────────────────────────────
    {
      key: :contract_type,
      label: 'Contract Type',
      type: :enum,
      options: ['MSA', 'SOW', 'NDA', 'Addendum', 'Supply Agreement', 'Service Agreement', 'Lease', 'Other'],
      dashboard: true,
      caf_column: :agreement_type,
      prompt_guide: 'Identify the agreement type. Choose from: MSA, SOW, NDA, Addendum, Supply Agreement, Service Agreement, Lease, Other. Return only the type name.'
    },
    {
      key: :change_in_addendum,
      label: 'Change in Addendum',
      type: :text,
      dashboard: true,
      caf_column: :change_in_addendum,
      # CONDITIONAL: only populated and displayed when contract_type == 'Addendum'
      # Omitted entirely for all other agreement types — not "Not Included", simply absent.
      conditional: { on: :contract_type, values: ['Addendum'] },
      prompt_guide: 'ONLY complete this field if contract_type is "Addendum". Summarise in 1-2 plain sentences what this addendum specifically changes from the parent agreement (e.g. "Extends the term by 12 months and reduces the monthly fee from ZAR 50,000 to ZAR 45,000", "Removes Schedule 3 and replaces the payment provisions with a per-seat pricing model"). Do NOT copy the clause. If contract_type is not "Addendum", omit this field from the JSON entirely.'
    },
    {
      key: :general_description,
      label: 'General Description of Services',
      type: :text,
      dashboard: false,
      caf_column: :mandate_description,
      prompt_guide: 'Write 2-3 plain sentences describing what services, goods, or rights are provided under this agreement, by whom, and to whom. This should read like an executive briefing. Do NOT quote the contract.'
    },

    # ── HIGH-LEVEL SUMMARY ────────────────────────────────────────────────────
    {
      key: :high_level_summary,
      label: 'High-Level Summary',
      type: :text,
      dashboard: true,
      caf_column: :high_level_summary,
      prompt_guide: <<~GUIDE
        Write a structured plain-English summary covering ALL of the following in 5-8 sentences.
        This is the single most important field — it must stand alone as a complete executive briefing.

        Cover in order:
        1. Commercial purpose: What is this agreement for? What business need does it serve?
        2. Parties: Who are the contracting parties and what is each party's role?
        3. Costing: What is the value? How is it structured (fixed fee, per unit, per hour, per head, minimum spend)?
           Include currency. If an SOW, state whether the value is confirmed or estimated.
        4. Term: How long does it run? Does it auto-renew?
        5. Key commercial risk: What is the single most important risk or unusual provision IG should be aware of?

        Do NOT quote the contract. Do NOT use legal jargon. Write as if briefing the CFO who has 30 seconds.
        Every sentence must add information — do not repeat yourself.
      GUIDE
    },

    # ── TERM ─────────────────────────────────────────────────────────────────
    {
      key: :effective_date,
      label: 'Effective Date',
      type: :date,
      dashboard: true,
      caf_column: :effective_date,
      prompt_guide: 'Return the date the agreement becomes effective as YYYY-MM-DD. If only month and year stated, use the 1st. Return null if not stated.'
    },
    {
      key: :expiry_date,
      label: 'Expiry Date',
      type: :date,
      dashboard: true,
      caf_column: :expiry_date,
      prompt_guide: 'Return the date the agreement expires as YYYY-MM-DD. Return null if evergreen or no end date — and set auto_renewal accordingly.'
    },
    {
      key: :period,
      label: 'Period',
      type: :string,
      dashboard: true,
      caf_column: :agreement_term,
      prompt_guide: 'Return the duration of the agreement as a plain string (e.g. "3 years", "24 months", "12 months rolling", "Perpetual", "Until project completion"). Do NOT state the start/end dates — those are captured separately. Return null if not determinable.'
    },
    {
      key: :auto_renewal,
      label: 'Evergreen/Auto-renewal (Y/N)',
      type: :boolean,
      dashboard: true,
      caf_column: :auto_renewal,
      prompt_guide: 'Return true (Y) if the agreement auto-renews unless notice is given. Return false (N) if it terminates at expiry with no renewal. Return null if not stated.'
    },
    {
      key: :notice_period_days,
      label: 'Notice Period (days)',
      type: :integer,
      dashboard: true,
      caf_column: :notice_period_days,
      prompt_guide: 'Return the notice period for cancellation or non-renewal as a plain integer number of days. Convert: 1 month = 30 days, 3 months = 90 days, 6 months = 180 days. Return null if not stated.'
    },

    # ── CANCELLATION ─────────────────────────────────────────────────────────
    {
      key: :cancellation_for_convenience,
      label: 'Cancellation — For Convenience',
      type: :string,
      dashboard: true,
      caf_column: :cancellation_for_convenience,
      prompt_guide: 'Summarise the termination-for-convenience right in one sentence. State who can terminate and the required notice (e.g. "Either party may terminate on 30 days written notice", "IG may terminate on 60 days notice; counterparty has no convenience termination right"). Do NOT copy the clause. If this right is not included in the agreement, return "Not Included".'
    },
    {
      key: :cancellation_breach,
      label: 'Cancellation — Breach',
      type: :string,
      dashboard: true,
      caf_column: :cancellation_breach,
      prompt_guide: 'Summarise the termination-for-breach right in one sentence. State the cure period if any (e.g. "Either party may terminate on 14 days notice if material breach is not remedied", "Immediate termination on insolvency"). Do NOT copy the clause. If the agreement has no breach termination provision, return "Not Included".'
    },

    # ── LIMITATION OF LIABILITY ───────────────────────────────────────────────
    {
      key: :liability_exclusion_indirect,
      label: 'Exclusion of Indirect/Consequential Loss',
      type: :string,
      dashboard: true,
      caf_column: :liability_exclusion_indirect,
      prompt_guide: 'State whether indirect and consequential loss is excluded. Use one of: "Yes — both parties exclude indirect and consequential loss", "Yes — supplier excludes only", "Partial — [describe what is excluded]". Do NOT copy the clause. If there is no such exclusion, return "Not Included".'
    },
    {
      key: :liability_aggregate_cap,
      label: 'Aggregate Liability Cap',
      type: :string,
      dashboard: true,
      caf_column: :liability_cap,
      prompt_guide: "Summarise the aggregate liability cap in one sentence (e.g. \"Capped at 12 months' fees paid prior to the claim\", \"Limited to ZAR 500,000\", \"Uncapped\"). Do NOT copy the clause. If there is no aggregate cap, return \"Not Included\" — this is a significant risk flag."
    },

    # ── KEY PROVISIONS ────────────────────────────────────────────────────────
    {
      key: :data_protection_clause,
      label: 'Data Protection Clause',
      type: :string,
      dashboard: true,
      caf_column: :data_protection_clause,
      prompt_guide: 'Summarise the data protection provisions in one sentence. State whether POPIA is referenced, whether a data processing agreement is included, and any notable obligations (e.g. "POPIA-compliant DPA included; supplier must notify of breaches within 72 hours", "Standard GDPR data processing addendum attached"). Do NOT copy the clause. Return "Not Included" if the agreement contains no data protection provisions.'
    },
    {
      key: :change_of_control,
      label: 'Change of Control',
      type: :enum,
      options: ['No provision', 'Notification only', 'Consent required', 'Prohibited', 'Breach/Termination trigger'],
      dashboard: true,
      caf_column: :change_of_control,
      prompt_guide: 'Classify the change-of-control provision using exactly one of these values: "No provision", "Notification only", "Consent required", "Prohibited", "Breach/Termination trigger". If the agreement allows a change of control but requires prior written consent, return "Consent required". If a change of control constitutes a breach or allows termination, return "Breach/Termination trigger". Return "No provision" if the agreement is silent.'
    },
    {
      key: :ip_ownership,
      label: 'IP Ownership',
      type: :string,
      dashboard: false,
      caf_column: :ip_ownership,
      prompt_guide: 'Summarise IP ownership in one sentence (e.g. "All IP created under this agreement vests in IG on creation", "Supplier retains all background IP; foreground IP is jointly owned"). Do NOT copy the clause. Return "Not Included" if the agreement contains no IP provisions.'
    },

    # ── COMMERCIAL ────────────────────────────────────────────────────────────
    {
      key: :sow_value,
      label: 'SOW Stated or Est. $ Value',
      type: :string,
      dashboard: true,
      caf_column: :agreement_value,
      prompt_guide: 'Return the total or annual contract value as a plain string including currency (e.g. "ZAR 1,200,000 per annum", "USD 85,000 total (estimated)", "ZAR 450,000 per SOW"). If the value is not fixed, state it as estimated. Do NOT copy pricing clauses. Return null if no value is determinable.'
    },
    {
      key: :minimum_spend,
      label: '$ Minimums',
      type: :string,
      dashboard: true,
      caf_column: :minimum_spend,
      prompt_guide: 'State any minimum spend, minimum volume, or minimum commitment in one plain sentence (e.g. "Minimum monthly spend of ZAR 25,000", "Minimum 100 units per quarter"). Return "Not Included" if there is no minimum commitment.'
    },
    {
      key: :pricing_structure,
      label: 'Pricing in Contract',
      type: :array,
      options: ['$/sale', '$/hr', '$/head', 'Fixed fee', 'Retainer', 'Milestone', 'Not Included'],
      dashboard: true,
      caf_column: :pricing_structure,
      prompt_guide: 'List ALL applicable pricing structures as a JSON array — agreements often combine multiple types. Options: "$/sale" (per transaction/unit sold), "$/hr" (time and materials, hourly), "$/head" (per person/seat/user), "Fixed fee" (lump sum), "Retainer" (monthly fixed), "Milestone" (payment on deliverables). Return ["Not Included"] if the agreement contains no pricing terms. Example: ["Fixed fee", "$/head"] for a combined model.'
    },
    {
      key: :payment_terms_days,
      label: 'Payment Terms (days from invoice)',
      type: :integer,
      dashboard: true,
      caf_column: :payment_terms_days,
      prompt_guide: 'Return the payment term as a plain integer number of days from invoice date (e.g. "Net 30" → 30, "45 days from invoice" → 45). Return null if not a commercial agreement or if payment terms are not stated.'
    },
    {
      key: :currency,
      label: 'Currency',
      type: :string,
      dashboard: false,
      caf_column: :currency,
      prompt_guide: 'Return the ISO 4217 currency code (ZAR, USD, EUR, GBP). Default to ZAR for South African agreements where currency is not explicitly stated.'
    },

    # ── STRUCTURED PAYMENT TERMS ─────────────────────────────────────────────
    {
      key: :payment_terms_structured,
      label: 'Payment Terms (Detailed)',
      type: :payment_terms,
      dashboard: false,
      caf_column: :payment_terms_structured,
      prompt_guide: <<~GUIDE
        List ALL payment obligations as a JSON array. Payments may flow in either
        direction — IG paying the counterparty, the counterparty paying IG, or both.
        Each entry must have:
          direction: "ig_pays" (IG pays counterparty) or "cp_pays" (counterparty pays IG)
          type: one of $/sale | $/hr | $/head | Fixed fee | Retainer | Milestone | Revenue share % | Other
          amount: the rate/value as a string including currency (e.g. "ZAR 450", "15%", "USD 100k")
          frequency: e.g. "per seat per month", "per transaction", "per annum", "one-off"
          notes: any important qualifier (optional, blank string if none)
        Example for a two-way arrangement:
        [
          {"direction":"cp_pays","type":"$/head","amount":"ZAR 450","frequency":"per seat per month","notes":"minimum 50 seats"},
          {"direction":"ig_pays","type":"Revenue share %","amount":"2%","frequency":"per transaction","notes":"on net revenue"}
        ]
        Return [] if no payment terms are stated.
      GUIDE
    },

    # ── COMMERCIAL TERMS (CONTINUED) ─────────────────────────────────────────
    {
      key: :price_escalation,
      label: 'Price Escalation',
      type: :string,
      dashboard: true,
      caf_column: :price_escalation,
      prompt_guide: 'Summarise any price escalation provisions in one sentence. State the trigger and the mechanism (e.g. "Annual CPI increase applies from Year 2 with 30 days notice", "Fixed 5% annual escalation on 1 January each year", "Ad hoc — supplier may increase on 60 days notice"). Return "Not Included" if the agreement has no price escalation provision — note this as neutral (no escalation risk, but also no price protection).'
    },
    {
      key: :exclusivity,
      label: 'Exclusivity',
      type: :enum,
      options: ['None', 'IG exclusive (locked in)', 'Counterparty exclusive', 'Mutual exclusivity'],
      dashboard: true,
      caf_column: :exclusivity,
      prompt_guide: "Classify any exclusivity provision. \"IG exclusive (locked in)\" means IG is obligated to use only this supplier for the relevant services. \"Counterparty exclusive\" means the counterparty may not supply IG's competitors. \"Mutual exclusivity\" means both restrictions apply. \"None\" if there is no exclusivity. Return \"Not Included\" only if the word or concept of exclusivity is expressly stated as not applying. Default to \"None\" if the contract is silent."
    },
    {
      key: :assignment,
      label: 'Assignment / Novation',
      type: :enum,
      options: ['Consent required', 'Notice only', 'Freely assignable', 'Prohibited', 'No provision'],
      dashboard: true,
      caf_column: :assignment,
      prompt_guide: 'Classify whether the agreement can be assigned to a third party. "Consent required" — written consent of the other party needed before assignment. "Notice only" — assignment permitted but the other party must be notified. "Freely assignable" — no restriction. "Prohibited" — assignment is expressly prohibited. "No provision" — agreement is silent on assignment. This is different from change of control — it covers voluntary assignment of rights by either party.'
    },

    # ── ENFORCEMENT ──────────────────────────────────────────────────────────
    {
      key: :dispute_resolution,
      label: 'Dispute Resolution',
      type: :string,
      dashboard: true,
      caf_column: :dispute_resolution,
      prompt_guide: 'Summarise the dispute resolution mechanism in one sentence. State the process and forum (e.g. "Mediation first, then AFSA arbitration in Johannesburg", "Litigation in the South Gauteng High Court", "ICC arbitration, seat London, English law"). Return "Not Included" if the agreement has no dispute resolution clause — default in SA is High Court litigation.'
    },
    {
      key: :sla_penalties,
      label: 'SLA / Performance Penalties',
      type: :string,
      dashboard: true,
      caf_column: :sla_penalties,
      prompt_guide: 'Summarise any service level commitments and the remedy for breach in one sentence (e.g. "99.9% uptime SLA; failure triggers service credits up to 10% of monthly fee", "Response time SLAs in Schedule 2; persistent failure entitles IG to terminate"). Return "Not Included" if the agreement contains no performance standards or penalties.'
    },

    # ── OPERATIONAL RIGHTS ───────────────────────────────────────────────────
    {
      key: :renewal_options,
      label: 'Renewal / Extension Options',
      type: :string,
      dashboard: true,
      caf_column: :renewal_options,
      prompt_guide: 'Describe any option rights to extend or renew beyond the initial term, in one sentence (e.g. "IG may extend for up to 2 further 12-month periods on 60 days notice", "Counterparty may offer renewal on new terms 90 days before expiry"). This is different from auto-renewal — these are optional extensions IG can choose to exercise. Return "Not Included" if no extension options exist.'
    },
    {
      key: :audit_rights,
      label: 'Audit Rights',
      type: :string,
      dashboard: false,
      caf_column: :audit_rights,
      prompt_guide: "State whether IG has the right to audit the counterparty in one sentence (e.g. \"IG may audit supplier's financial records and systems on 14 days notice, once per year\", \"No audit right — supplier provides annual compliance report only\"). Return \"Not Included\" if the agreement contains no audit rights."
    },
    {
      key: :subcontracting,
      label: 'Subcontracting',
      type: :string,
      dashboard: false,
      caf_column: :subcontracting,
      prompt_guide: "Summarise the subcontracting provisions in one sentence (e.g. \"Supplier may subcontract with IG's prior written consent\", \"Subcontracting permitted without consent but supplier remains liable\", \"Subcontracting prohibited\"). Return \"Not Included\" if the agreement is silent — note that silence typically means the supplier can subcontract freely, which may be a risk for data-sensitive agreements."
    },

    # ── RISK FLAGS ────────────────────────────────────────────────────────────
    {
      key: :material_risks,
      label: 'Material Risks',
      type: :array,
      dashboard: true,
      caf_column: :key_risks,
      prompt_guide: 'List up to 3 material legal or commercial risks — one plain sentence each. These are risks IG carries, not neutral observations. Examples: "No aggregate liability cap — IG has unlimited exposure for any claim", "Auto-renewal requires 90 days notice — high risk of unintended rollover", "Counterparty retains all IP created — IG cannot reuse work product". Do NOT copy clauses. Write as risk statements a CLO or CFO would act on.'
    },
    {
      key: :governing_law,
      label: 'Governing Law',
      type: :string,
      dashboard: true,
      caf_column: :governing_law,
      prompt_guide: 'Return the governing law jurisdiction (e.g. "Republic of South Africa", "England and Wales", "New York"). Return null if not stated.'
    },
    {
      key: :amends_or_relates_to,
      label: 'Amends / Relates To',
      type: :array,
      dashboard: true,
      caf_column: nil,
      prompt_guide: 'If this is an addendum, SOW, or schedule, list the names or references of parent agreements (e.g. "Master Services Agreement dated 1 March 2024", "SOW-3 under the IG-Acme MSA"). Return an empty array [] if standalone.'
    }
  ].freeze

  def self.field(key)
    FIELDS.find { |f| f[:key] == key }
  end

  def self.dashboard_fields
    FIELDS.select { |f| f[:dashboard] }
  end

  def self.caf_column_fields
    FIELDS.select { |f| f[:caf_column] }
  end

  # Returns the fields that are active for a given workflow instance.
  # Filters out conditional fields whose condition is not met.
  def self.active_fields_for(workflow)
    FIELDS.reject do |field|
      cond = field[:conditional]
      next false unless cond

      comparand = begin
        workflow.public_send(cond[:on])
      rescue NoMethodError
        nil
      end
      !cond[:values].include?(comparand.to_s)
    end
  end

  # Variant for building the extraction prompt — takes a hash of known values
  # rather than a model instance.
  def self.active_fields_for_type(contract_type_value)
    FIELDS.reject do |field|
      cond = field[:conditional]
      next false unless cond

      !cond[:values].include?(contract_type_value.to_s)
    end
  end
end
