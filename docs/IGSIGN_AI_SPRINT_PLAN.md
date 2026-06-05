# IGSIGN — Full Product Sprint Plan (v2)

**Owner:** Craig Lawrence (CLO, Ignition Group)
**Project:** IGSIGN — DocuSeal fork (Rails 8.1.3, PostgreSQL, on-prem 172.30.0.30)
**Repo:** github.com/CraigIG4/docuseal, branch: master
**Updated:** 2026-06-04

---

## What IGSIGN Is (Full Vision)

IGSIGN is not a signing engine. It is a **bespoke compliance-driven contract execution platform** that:

1. Enforces IG's internal signing protocol through pre-populated approval chains from approval matrices
2. Reads the uploaded contract and auto-populates the CAF — including summaries of key clauses
3. Auto-detects and places signature, initial, date, and text fields on the contract itself
4. Produces a CAF that is electronically signed in the appropriate signing spaces, serving as the single compliance memorial for every agreement that goes through IG
5. Auto-populates a contracts dashboard by IG entity, counterparty, and commercial relationship — showing risk exposure and obligations across the business
6. Provides **GCinmyPOCKET** — an AI general counsel assistant — to internal IG signers (Stage 0 and Stage 1 only)

**Counterparty signers (Stage 2) receive none of the AI tooling.** The signing form for a counterparty is a clean DocuSeal signing experience with no chatbot, no internal data, and no visibility into IG's internal approval process.

---

## The Six Pillars

| Pillar | Name | Build status |
|---|---|---|
| 1 | Compliance routing — approval matrix → pre-populated signers | Largely ✅ (CafApprovalMatrix, CafSubmissionCreator) |
| 2 | Smart CAF pre-fill — parse contract → auto-fill CAF wizard fields | Infrastructure ✅, wiring ❌ |
| 3 | Auto field placement — AI detects signature/initial/date positions | ONNX model ✅, auto-trigger in wizard ❌ |
| 4 | CAF as signed compliance memorial | CafPdfGenerator ✅, signing loop ✅, audit bundle ✅ |
| 5 | Contracts dashboard — risk/exposure by entity and counterparty | ❌ Not built |
| 6 | GCinmyPOCKET — internal signer AI assistant | ContractParser ✅ (inert), ChatService ❌, UI ❌ |

---

## GCinmyPOCKET — Scope and Context Assembly

**Who gets it:** Stage 0 (internal approval signers) and Stage 1 (IG executive signers — CEO, COO) ONLY.
Stage 2 counterparty signers see no chatbot. The signing form for counterparties renders without the panel.

**What it knows:**
1. The document(s) in the current signing envelope — extracted via Pdfium (already built)
2. Other agreements involving the same counterparty — surfaced automatically from existing CafWorkflow records for the same Company, and/or manually attached by legal ops
3. The approval process for this agreement — derivable from the CafApprovalMatrix and the agreement's stage data

**No SharePoint integration is required.** Legal ops can manually attach relevant related documents (MSA, schedules, prior SOWs) directly within IGSIGN. The system also auto-suggests linking based on counterparty match from existing workflows. This is simpler, more controlled, and does not require Azure AI Search or Microsoft Graph API for the pilot.

**When a question is asked**, the bot assembles context in this priority order:
1. The document currently being signed (highest weight — most specific)
2. Manually attached related documents (if any — ordered by type: Addendum > SOW > Schedule > MSA)
3. Other CafWorkflows for the same counterparty company where `parsed_contract_data` is present (auto-pulled)

---

## Agents

| Agent | File | Use for |
|---|---|---|
| `igsign-rails-analyst` | `.claude/agents/igsign-rails-analyst.md` | Tracing bugs, auditing services before writing |
| `igsign-data-modeller` | `.claude/agents/igsign-data-modeller.md` | Schema design, migration review |
| `igsign-frontend-reviewer` | `.claude/agents/igsign-frontend-reviewer.md` | ERB/Stimulus/Turbo review |
| `igsign-qa-verifier` | `.claude/agents/igsign-qa-verifier.md` | RSpec coverage audit |

**Create in Sprint 0:**

`.claude/agents/igsign-rag-architect.md`:

```markdown
---
name: igsign-rag-architect
description: Use when auditing the IGSIGN AI pipeline — ContractParser, ContractParsingJob, ContractChatService, GCinmyPOCKET, document text extraction, prompt files, or context assembly. Read-only — reports findings, parent session performs writes.
tools: Read, Grep, Glob, Bash
model: sonnet
---

You are a senior AI/ML engineer specialising in RAG systems built on Rails. You are read-only: investigate, trace, report. Do not edit.

IGSIGN AI pipeline:
- ContractParser (app/services/contract_parser.rb) — metadata extraction via OpenRouter
- ContractParsingJob (app/jobs/contract_parsing_job.rb) — Sidekiq job, runs after document upload
- ContractChatService (app/services/contract_chat_service.rb) — GCinmyPOCKET backend
- DocumentMetadatas.build_text_runs (lib/document_metadatas.rb) — Pdfium text extraction
- Prompt files: config/prompts/extract_contract_v1.md, config/prompts/gcip_chat_v1.md
- CafWorkflow#parsed_contract_data (jsonb) — stores extraction results

Always check:
1. Is internal_only filtering applied? Counterparty signers must never receive internal document context.
2. Is the submitter token scoped to the correct workflow? Tokens from one agreement must not access another's documents.
3. Is GCinmyPOCKET gated to Stage 0/1 only? It must not render for Stage 2 counterparty signers.
4. Are chat exchanges being written to chat_audit_logs?

Report: findings, security concerns, prompt quality issues, failure modes, recommended fix (file and line specific).
```

---

## Data Architecture — CafFieldSchema (Read Before Building Anything)

Every field that flows from contract → AI extraction → manual fallback → CAF pre-fill → dashboard is defined **once** in a shared Ruby constant: `app/lib/caf_field_schema.rb`.

This constant is the single source of truth. The extraction prompt is generated from it. The manual fallback form is rendered from it. The dashboard queries from it. If a field is added here, it appears in all three places automatically.

```ruby
# app/lib/caf_field_schema.rb
# Defines every field that flows from contract extraction through to the dashboard.
# type:          determines input type in manual fallback form and JSON output format
# dashboard:     true means this field appears on the contracts dashboard
# caf_column:    the caf_workflows column this field maps to (nil = jsonb only)
# prompt_guide:  the per-field extraction instruction embedded in the LLM prompt
#                CRITICAL: every guide must say SUMMARIZE not copy. See methodology below.

## "Not Included" Rule

For all legal/commercial provision fields: if the contract does not contain the provision, the extraction
must return the string `"Not Included"` — not null. Null means the extraction did not run or the field
could not be determined. `"Not Included"` means the extraction ran and the provision is absent.

This distinction matters for the contracts register: a blank cell means unknown, a cell reading
"Not Included" means reviewed and confirmed absent. The dashboard shows unknown fields with an amber
indicator and "Not Included" fields as a clear stated value.

Fields that use this rule: all provision fields (liability_exclusion_indirect, liability_aggregate_cap,
cancellation_for_convenience, cancellation_breach, data_protection_clause, change_of_control,
minimum_spend, pricing_structure, ip_ownership, price_escalation, exclusivity, assignment,
dispute_resolution, sla_penalties, renewal_options, audit_rights, subcontracting).

`change_in_addendum` does NOT use this rule — it is a conditional field that only exists for Addendum
agreements. When the contract type is not an Addendum, the field is omitted entirely (not "Not Included").

Fields that do NOT use this rule (null is correct for absent): dates, booleans, integers, currency.

---

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
      prompt_guide: 'Summarise the aggregate liability cap in one sentence (e.g. "Capped at 12 months\' fees paid prior to the claim", "Limited to ZAR 500,000", "Uncapped"). Do NOT copy the clause. If there is no aggregate cap, return "Not Included" — this is a significant risk flag.'
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
      type: :enum,
      options: ['$/sale', '$/hr', '$/head', 'Fixed fee', 'Retainer', 'Milestone', 'Mixed', 'Not Included'],
      dashboard: true,
      caf_column: :pricing_structure,
      prompt_guide: 'Classify the pricing structure using the most accurate option: "$/sale" (per transaction/unit sold), "$/hr" (time and materials, hourly), "$/head" (per person/seat/user), "Fixed fee" (lump sum), "Retainer" (monthly fixed), "Milestone" (payment on deliverables), "Mixed" (combination). Return "Not Included" if the agreement contains no pricing terms.'
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
      prompt_guide: 'Classify any exclusivity provision. "IG exclusive (locked in)" means IG is obligated to use only this supplier for the relevant services. "Counterparty exclusive" means the counterparty may not supply IG\'s competitors. "Mutual exclusivity" means both restrictions apply. "None" if there is no exclusivity. Return "Not Included" only if the word or concept of exclusivity is expressly stated as not applying. Default to "None" if the contract is silent.'
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
      prompt_guide: 'State whether IG has the right to audit the counterparty in one sentence (e.g. "IG may audit supplier\'s financial records and systems on 14 days notice, once per year", "No audit right — supplier provides annual compliance report only"). Return "Not Included" if the agreement contains no audit rights.'
    },
    {
      key: :subcontracting,
      label: 'Subcontracting',
      type: :string,
      dashboard: false,
      caf_column: :subcontracting,
      prompt_guide: 'Summarise the subcontracting provisions in one sentence (e.g. "Supplier may subcontract with IG\'s prior written consent", "Subcontracting permitted without consent but supplier remains liable", "Subcontracting prohibited"). Return "Not Included" if the agreement is silent — note that silence typically means the supplier can subcontract freely, which may be a risk for data-sensitive agreements.'
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
  # Used by: extraction prompt generator, manual fallback form renderer, CAF template.
  #
  # Example: change_in_addendum is omitted entirely when agreement_type != 'Addendum'.
  def self.active_fields_for(workflow)
    FIELDS.reject do |field|
      cond = field[:conditional]
      next false unless cond
      comparand = workflow.public_send(cond[:on]) rescue nil
      !cond[:values].include?(comparand.to_s)
    end
  end

  # Variant for use when building the extraction prompt — takes a hash of known values
  # (e.g. {'contract_type' => 'Addendum'}) rather than a model instance.
  # The ContractParser calls this after a first-pass extraction of contract_type.
  def self.active_fields_for_type(contract_type_value)
    FIELDS.reject do |field|
      cond = field[:conditional]
      next false unless cond
      !cond[:values].include?(contract_type_value.to_s)
    end
  end
end
```

**Why this matters:** Without `CafFieldSchema`, the extraction prompt, the manual form, and the dashboard all define their own field lists independently. They drift. The dashboard queries a field that the form doesn't show. The prompt extracts a field the dashboard never reads. This constant eliminates that drift.

**The extraction prompt is generated from this schema** — not hand-written. Each field's `prompt_guide` is the LLM instruction for that field. The `ContractParser` builds the prompt dynamically from `CafFieldSchema::FIELDS`, so adding a new field to the schema automatically adds it to both the prompt and the manual form.

---

## Extraction Methodology — Summarise, Never Copy

This must be enforced throughout. The LLM should produce distilled, human-readable values — not verbatim contract text.

**Wrong (copy):**
> `liability_cap`: "In no event shall either Party's aggregate liability to the other Party under or in connection with this Agreement, whether arising in contract, tort (including negligence), breach of statutory duty or otherwise, exceed the total Fees paid or payable by the Customer in the twelve (12) calendar months immediately preceding the event giving rise to the claim."

**Right (summary):**
> `liability_cap`: "Capped at 12 months' fees paid prior to the claim."

**Wrong:**
> `key_obligations[0]`: "The Service Provider shall provide the Services described in Schedule 1 in accordance with the Service Levels set out in Schedule 2."

**Right:**
> `key_obligations[0]`: "Provider must deliver services per Schedule 1 at the agreed service levels."

The extraction prompt enforces this through per-field `prompt_guide` instructions. Every guide includes explicit "Do NOT copy the clause" or "Do NOT quote" instruction. This is non-negotiable — copied clauses make the CAF unreadable and break dashboard field sizing.

---

## Quality Gates (every sprint)

```
GATE 1: RuboCop — rubocop --autocorrect-all, zero offences
GATE 2: RSpec — bundle exec rspec, green
GATE 3: Smoke test — rake igsign:smoke_test, passing
GATE 4: Brakeman — no new HIGH severity findings
GATE 5: Manual browser verification of the changed feature on 172.30.0.30
```

Do not start the next sprint until all gates pass.

---

## Sprint 0 — Foundation: Schema + Parsing Pipeline (~7h)

**Goal:** Create the shared field schema, add missing native columns for the dashboard, make ContractParser functional, and build the manual fallback form. This sprint creates the data foundation everything else builds on.

### Task 0.0 — Create CafFieldSchema

Create `app/lib/caf_field_schema.rb` exactly as defined in the Data Architecture section above. This file must exist before the extraction prompt or manual form are built — both are derived from it.

### Task 0.0b — Migrations for missing native columns

`caf_workflows` is missing columns that the dashboard needs as native, indexable values. Querying all dashboard metrics from jsonb alone will be slow and fragile as volume grows.

Create migration `add_dashboard_columns_to_caf_workflows`. These are the native columns that the dashboard queries — derived from `CafFieldSchema.caf_column_fields`:

```ruby
# Term
add_column :caf_workflows, :effective_date,   :date
add_column :caf_workflows, :expiry_date,       :date
add_column :caf_workflows, :auto_renewal,      :boolean
add_column :caf_workflows, :notice_period_days, :integer

# Cancellation
add_column :caf_workflows, :cancellation_for_convenience, :string
add_column :caf_workflows, :cancellation_breach,          :string

# Limitation of liability
add_column :caf_workflows, :liability_exclusion_indirect, :string
add_column :caf_workflows, :liability_cap,                :string

# Key provisions
add_column :caf_workflows, :data_protection_clause, :string
add_column :caf_workflows, :change_of_control,      :string
add_column :caf_workflows, :ip_ownership,           :string

# Commercial
add_column :caf_workflows, :minimum_spend,        :string
add_column :caf_workflows, :pricing_structure,    :string
add_column :caf_workflows, :payment_terms_days,   :integer
add_column :caf_workflows, :currency,             :string, default: 'ZAR'
add_column :caf_workflows, :governing_law,        :string

# Commercial (continued)
add_column :caf_workflows, :price_escalation, :string
add_column :caf_workflows, :exclusivity,      :string
add_column :caf_workflows, :assignment,       :string

# Enforcement
add_column :caf_workflows, :dispute_resolution, :string
add_column :caf_workflows, :sla_penalties,      :string

# Operational rights
add_column :caf_workflows, :renewal_options, :string
add_column :caf_workflows, :audit_rights,    :string
add_column :caf_workflows, :subcontracting,  :string

# Addendum (conditional — only populated when agreement_type = 'Addendum')
add_column :caf_workflows, :change_in_addendum, :text

# Provenance tracking
add_column :caf_workflows, :parsed_data_provenance, :jsonb, default: {}

# Indexes for dashboard queries
add_index :caf_workflows, :expiry_date
add_index :caf_workflows, :auto_renewal
add_index :caf_workflows, :change_of_control
add_index :caf_workflows, [:entity, :status]
add_index :caf_workflows, [:account_id, :expiry_date]
```

`parsed_data_provenance` tracks per-field source: `{ "payment_terms_days": "ai", "agreement_value": "manual", "effective_date": "ai" }`. The dashboard uses this to show data quality indicators — fields manually entered are shown with a different indicator than AI-extracted fields.

**After this migration:** `ContractParsingJob` must be updated to write dashboard-relevant fields to both `parsed_contract_data` (full JSON) and the new native columns. `CafFieldSchema.caf_column_fields` drives this mapping.

### Task 0.1 — Build the extraction prompt from CafFieldSchema

**Do not hand-write `config/prompts/extract_contract_v1.md`.**

Instead, build `ContractParser` to generate the prompt dynamically from `CafFieldSchema::FIELDS`, using each field's `key`, `type`, and `prompt_guide`.

**Two-pass extraction for conditional fields:**
Because `change_in_addendum` only applies to Addendum agreements, the extraction runs as follows:
1. First pass — extract `contract_type` only (minimal prompt, fast).
2. Call `CafFieldSchema.active_fields_for_type(contract_type)` to get the relevant field list.
3. Second pass — full extraction using only the active fields.

This prevents the LLM from attempting to populate `change_in_addendum` when the document is not an Addendum, which causes hallucination.

The generated prompt section looks like:

```
For each field below, follow the specific instruction exactly.
CRITICAL RULE: Summarise — never copy clause text verbatim. Write values in plain English
as if briefing an executive who has not read the contract.

contract_type: Identify the agreement type from this list: MSA, SOW, NDA, Addendum,
  Supply Agreement, Service Agreement, Lease, Other. Return only the type name.

effective_date: Return the date the agreement becomes effective as YYYY-MM-DD...

[one instruction per field, generated from CafFieldSchema]
```

Return ONLY valid JSON with the keys matching CafFieldSchema field keys. No markdown, no preamble.

This approach means adding a field to `CafFieldSchema` automatically updates the extraction prompt — no manual prompt editing required.

### Task 0.2 — Wire ContractParsingJob to the upload flow

**Investigate first:** Use `igsign-rails-analyst` to find where CafWorkflow is created and the template document attached — likely `AgreementsController#process_upload` or `CafSubmissionCreator`. Report the exact line.

**Then write:** After the blob is committed to storage (not in a transaction callback), add:
```ruby
ContractParsingJob.perform_later(caf_workflow.id)
```

**Update ContractParsingJob** to write native columns after saving `parsed_contract_data`:
```ruby
# After: agreement.update_columns(parsed_contract_data: result)
native_updates = {}
provenance_updates = {}
CafFieldSchema.caf_column_fields.each do |field|
  value = result[field[:key].to_s]
  next if value.nil?
  native_updates[field[:caf_column]] = value
  provenance_updates[field[:key].to_s] = 'ai'
end
native_updates[:parsed_data_provenance] = agreement.parsed_data_provenance.merge(provenance_updates)
agreement.update_columns(**native_updates) if native_updates.any?
```

### Task 0.2b — Extract IgsignLlmClient shared module

`ContractParser` and `ContractChatService` (Sprint 3) both need an authenticated Faraday client pointed at the OpenRouter-compatible endpoint. Build it once here — do not duplicate it in Sprint 3.

Create `app/lib/igsign_llm_client.rb`:

```ruby
# Thin wrapper around the OpenRouter-compatible LLM API.
# Used by ContractParser (extraction) and ContractChatService (GCinmyPOCKET).
# Sprint 6 will add Azure OpenAI fallback here without changing callers.
module IgsignLlmClient
  BASE_URL  = -> { ENV.fetch('AI_BASE_URL', 'https://openrouter.ai/api/v1') }
  API_KEY   = -> { ENV['AI_API_KEY'] }
  DEFAULT_MODEL = 'meta-llama/llama-3.3-70b-instruct:free'

  def self.configured?
    API_KEY.call.present?
  end

  # Sends a messages array to the chat completions endpoint.
  # Returns the content string on success, raises on HTTP/network error.
  def self.chat(messages, model: nil, temperature: 0.2)
    raise 'AI_API_KEY not configured' unless configured?

    conn = Faraday.new(url: BASE_URL.call) do |f|
      f.request :json
      f.response :json
      f.headers['Authorization'] = "Bearer #{API_KEY.call}"
      f.headers['HTTP-Referer'] = 'https://igsign.ignitiongroup.co.za'
      f.headers['X-Title'] = 'IGSIGN'
    end

    resp = conn.post('chat/completions', {
      model: model || ENV.fetch('AI_MODEL', DEFAULT_MODEL),
      messages:,
      temperature:
    })

    raise "HTTP #{resp.status}: #{resp.body}" unless resp.success?
    content = resp.body.dig('choices', 0, 'message', 'content')
    raise 'Empty LLM response' if content.blank?
    content
  end
end
```

Update `ContractParser` to call `IgsignLlmClient.chat(messages)` instead of building its own Faraday client. Sprint 3's `ContractChatService` will do the same — no duplication.

### Task 0.3 — Create igsign-rag-architect agent

Create `.claude/agents/igsign-rag-architect.md` with the content specified in the Agents section above.

### Task 0.4 — Manual fallback form (the primary review interface)

This is not a simple re-parse button. It is the main interface for legal ops to review, correct, and complete contract data — whether the AI extracted it or not.

Under `/legal_ops/workflows/:id/contract_data` (new route + controller action):

**Rendered from CafFieldSchema** — iterate `CafFieldSchema::FIELDS` and render the correct input for each:
- `:enum` → `<select>` with the options list
- `:date` → `<input type="date">`
- `:boolean` → radio buttons (Yes / No / Unknown)
- `:integer` → `<input type="number">`
- `:string` → `<input type="text">`
- `:text` → `<textarea>`
- `:array` → textarea with one item per line (save/load as JSON array)

**Pre-fill behaviour:**
- If `parsed_data_provenance[field_key] == 'ai'` → show field value + small "AI" badge (green, IG palette)
- If `parsed_data_provenance[field_key] == 'manual'` → show field value + "Manual" badge (grey)
- If no provenance entry → field is empty, no badge

**On save:**
- Write each field value to `parsed_contract_data` (merge, preserve other keys)
- Write dashboard fields to native columns via `CafFieldSchema.caf_column_fields` mapping
- Set `parsed_data_provenance[field_key] = 'manual'` for each field the user touched
- Show success flash: "Contract data saved. Dashboard will reflect these values."

**Parse status banner:**
- If `parsed_contract_data['error']` present → red banner "Automatic extraction failed: [error]. Please complete the fields below."
- If `parsed_contract_data` nil → amber banner "Extraction is pending or has not run. Fields shown are empty."
- If all dashboard fields populated → green banner "Contract data complete."
- "Re-parse" button always present — re-enqueues ContractParsingJob. Warn: "Re-parsing will overwrite AI-extracted fields but not manually entered fields." (Only overwrite where provenance is 'ai', preserve 'manual' values.)

**Link from agreement wizard:** The agreement wizard review step links to this page if any required CAF fields are empty after pre-fill.

### Task 0.5 — Verify end-to-end

1. Upload a test PDF → ContractParsingJob fires (logs)
2. `parsed_contract_data` populated, native columns updated (check DB)
3. Smart Summary card renders on review page
4. `/legal_ops/workflows/:id/contract_data` shows all fields, correct provenance badges
5. Edit a field manually → provenance changes to 'manual', native column updated
6. Re-parse → 'ai' fields overwritten, 'manual' fields preserved

**Gates:** All 5.

---

## Sprint 0.5 — CAF Redesign: PDF Engine + Template (~8h)

**Goal:** Replace LibreOffice HTML→PDF conversion with a proper rendering engine, redesign the CAF templates to include all contracts-register fields, and produce a professional, IG-branded legal document.

**Why this must happen before Sprint 1:** The CAF pre-fill (Sprint 1) only delivers value if the CAF looks like something you'd send to a CEO. LibreOffice strips CSS, ignores Google Fonts, and produces an ugly unstyled document regardless of how good the HTML template is. The rendering engine fix is a prerequisite.

### Task 0.5.1 — Switch from LibreOffice to Grover (Chrome headless)

**Current:** `CafPdfGenerator` runs LibreOffice via `system(SOFFICE, '--headless', '--convert-to', 'pdf', ...)`. LibreOffice has poor CSS support, ignores Google Fonts (requires network), and produces inconsistent layout.

**Replacement:** Grover gem — uses Chrome/Chromium headless via Puppeteer. Renders HTML exactly as a browser would. Supports Tailwind, DM Sans via Google Fonts (with internet) or a locally embedded font file (preferred for on-prem).

Add to Gemfile:
```ruby
gem 'grover'
```

Add to Dockerfile: `RUN apt-get install -y chromium chromium-driver`

Replace `CafPdfGenerator#convert_to_pdf`:
```ruby
def generate
  html = render_html
  Grover.new(html, format: 'A4', print_background: true,
             margin: { top: '15mm', bottom: '15mm', left: '15mm', right: '15mm' }).to_pdf
end
```

Note: The method now returns binary PDF data rather than a file path. Update callers accordingly. LibreOffice remains available in the image for DOCX→PDF conversion (the `convert_docx` path in `CafSubmissionCreator`) — do not remove it.

**Embed DM Sans locally.** Download DM Sans variable font files and add to `app/assets/fonts/`. Reference via a local `@font-face` declaration in `_shared_styles.html` — do not rely on Google Fonts CDN for a document that may be generated on an air-gapped server.

### Task 0.5.2 — Redesign long_form.html.erb with contracts-register fields

The redesigned long_form CAF must include all `CafFieldSchema::FIELDS` as displayable sections. Layout: A4, portrait, IG-branded header, clean table structure.

**Page 1 — Header and identity:**
```
[IG Logo left] [IG entity name right]
CONTRACT APPROVAL FORM — [AGREEMENT TYPE]
Reference: CAF-[ID] | Date: [date_prepared]
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
Entity:              [entity_name]         Reg No: [entity_registration]
Counterparty:        [counterparty_company] Reg No: [counterparty_registration]
Contract Type:       [agreement_type]      Relationship: [commercial_relationship]
Requestor:           [requestor_name]      Email: [requestor_email]
```

**Section A — High-Level Summary:**
Full-width text block. Not a table — this is the executive briefing paragraph. If the AI generated it, render as-is. If manually entered, same. Font: DM Sans 10pt, italic style if AI-generated (subtle indicator).

**Section B — Term and Cancellation (table, 2 columns):**
```
Effective Date      | [effective_date]
Expiry Date         | [expiry_date]
Period              | [period]
Auto-Renewal        | [Y / N]
Notice Period       | [X days]
─────────────────────────────────────────
For Convenience     | [cancellation_for_convenience]
Breach              | [cancellation_breach]
```

**Section C — Commercial Terms (table):**
```
SOW / Contract Value     | [sow_value]
Pricing Structure        | [pricing_structure]
$ Minimums               | [minimum_spend]
Payment Terms            | [payment_terms_days] days
Currency                 | [currency]
```
Addendum agreements only — rendered conditionally when `agreement_type == 'Addendum'`:
```
CHANGE FROM PARENT:      | [change_in_addendum]  ← amber left-border, distinct background
```
This section is completely absent for non-addendum agreements — no empty row, no "N/A".

**Section D — Limitation of Liability:**
```
Exclusion Indirect/Consequential | [liability_exclusion_indirect]
Aggregate Cap                    | [liability_aggregate_cap]
```
If either is "Not Included", display in amber/red text — visual risk flag.

**Section E — Key Provisions:**
```
Data Protection        | [data_protection_clause]
Change of Control      | [change_of_control]
Assignment             | [assignment]
IP Ownership           | [ip_ownership]
Governing Law          | [governing_law]
Dispute Resolution     | [dispute_resolution]
```

**Section F — Commercial Rights and Obligations:**
```
Price Escalation       | [price_escalation]
Exclusivity            | [exclusivity]
SLA / Penalties        | [sla_penalties]
Renewal Options        | [renewal_options]
Audit Rights           | [audit_rights]
Subcontracting         | [subcontracting]
```

**Section G — General Description of Services:**
Full-width text block. Plain paragraph — not a table.

**Section H — Material Risks:**
Numbered list. Each risk on its own line. If any risk is present, render section header in red (`#DC2626`). If empty, render "No material risks identified."

**Section I — Internal Approval (signature page — page break before):**
Existing signing rows layout, already functional. Keep as-is structurally, apply new CSS.

**General design rules:**
- Font: DM Sans, 9.5pt body, 11pt section headers
- Section headers: Arctic Black `#0B1722` background, white text, uppercase
- "Not Included" values: rendered in `#9CA3AF` (muted grey) — clearly present but de-emphasised
- Risk-flag values (no liability cap, no data protection): `#DC2626` red text
- Page numbers in footer: "Page X of Y — IGSIGN CAF-[ID] — CONFIDENTIAL"
- IG Green `#00C853` used sparingly: section header left-border accent only
- No horizontal rules that span full width — use table borders instead (LibreOffice used to mangle rules)

### Task 0.5.3 — Update short_form.html.erb and nda.html.erb

Apply the same CSS and font treatment. Short form omits Sections D, E (liability/provisions). NDA form keeps its existing structure but applies the new styles and font embedding.

### Task 0.5.4 — Verify PDF output

Generate a CAF from a test agreement on 172.30.0.30. Check:
1. DM Sans renders correctly (not falling back to Arial)
2. Arctic Black section headers render with colour (not stripped)
3. Tables are properly bordered
4. "Not Included" values render in grey
5. Page 2 (signing page) has a proper page break
6. PDF is generated in under 10 seconds

**Gates:** All 5.

---

## Sprint 1 — Smart CAF Pre-fill (Pillar 2, ~6h)

**Goal:** Use `parsed_contract_data` to auto-populate the agreement wizard fields. The requestor uploads a contract and the form fields are pre-filled from what the AI extracted — they review and correct rather than typing everything from scratch.

**Context:** `CafPdfGenerator` already maps wizard fields (mandate_description, agreement_purpose, agreement_value, payment_terms, key_risks, etc.) to the CAF template. These are currently entered manually. The extraction prompt in Sprint 0 was specifically designed to produce these values.

### Task 1.1 — Pre-fill wizard from CafFieldSchema + native columns

The pre-fill mapping is driven by `CafFieldSchema.caf_column_fields` — do not hardcode it. Iterate the schema, read each field's `caf_column`, and pre-fill the corresponding wizard input from the native column value (which was written by `ContractParsingJob` in Sprint 0).

Reading from native columns (not from the jsonb) is intentional — it's faster, type-safe, and consistent with what the dashboard reads. The jsonb is the raw extraction store; native columns are the promoted, usable values.

Pre-fill mapping examples (derived automatically from schema):

| CAF column | Schema field | Wizard input |
|---|---|---|
| `mandate_description` | mandate_description | Mandate textarea |
| `agreement_purpose` | agreement_purpose | Purpose field |
| `agreement_value` | agreement_value | Value field |
| `effective_date` | effective_date | Date picker |
| `expiry_date` | expiry_date | Date picker |
| `auto_renewal` | auto_renewal | Checkbox |
| `notice_period_days` | notice_period_days | Integer field |
| `governing_law` | governing_law | Text field |
| `liability_cap` | liability_cap | Text field |
| `high_level_summary` | summary | Summary textarea |
| `key_risks` | material_risks (joined with "; ") | Risks textarea |

Pre-fills are suggestions only — the requestor can edit. Never overwrite a field that already has a manually confirmed value (check `parsed_data_provenance[field] == 'manual'` before overwriting).

**UX:** Wizard must not block on parsing. If native columns are null (job still running or not yet run), form renders empty as normal. If populated, show banner: "Fields pre-filled from contract — please review." Each pre-filled field shows the AI badge from `parsed_data_provenance`.

### Task 1.2 — Auto-suggest amends_or_relates_to linkage

If `parsed_contract_data['amends_or_relates_to']` is present, show a banner on the Legal Ops workflow page:

> "This document references: [MSA Name, SOW-2]. Link related agreements for GCinmyPOCKET?"

Clicking shows a search modal to find and link existing CafWorkflows. Do not auto-link — legal ops confirms.

### Task 1.3 — RSpec for pre-fill logic

Test that pre-fill correctly maps each field and handles: null parsed_data (form renders empty), error key (form renders empty), partial data (only present fields pre-filled).

**Gates:** All 5.

---

## Sprint 2 — Auto Field Placement (Pillar 3, ~8h)

**Goal:** When a contract PDF is uploaded, automatically detect and place the DocuSeal signing fields (signature, initials, date, text boxes for name/address/email) at the correct positions in the document. The requestor reviews and adjusts rather than manually placing every field.

**Context:** DocuSeal already has this capability — `Templates::DetectFields` uses an ONNX ML model (`Templates::ImageToFields`) to detect field positions from rendered page images, combined with regex matching (SIGNATURE_REGEXP, DATE_REGEXP, NUMBER_REGEXP) and underscore-line detection. This is not being auto-triggered in the IGSIGN upload wizard.

**Investigate first:** Use `igsign-rails-analyst` to understand how `Templates::DetectFields` is currently triggered (likely via the template editor "auto-detect fields" button), what `Templates::ImageToFields::MODEL_PATH` (`tmp/model.onnx`) requires, and whether the ONNX model is present in the Docker image.

### Task 2.1 — Trigger field detection on upload

After a template attachment is processed in the upload flow, enqueue a `FieldDetectionJob` that calls `Templates::DetectFields.call(io, attachment:)` and saves the detected fields to the template schema. The job must handle the case where the ONNX model is absent (log a warning, skip silently — do not block).

**Do not re-implement field detection.** Use `Templates::DetectFields` exactly as it exists.

### Task 2.2 — Review step: field placement UI

On the agreement wizard's field-positioning step, show:
- The PDF pages with auto-detected fields overlaid
- Count of detected fields by type (e.g. "3 signature fields, 5 text fields, 2 date fields detected")
- A "Looks correct — proceed" button and an "Edit fields" button (which opens the DocuSeal template editor)
- Warning if zero fields detected (common for scanned PDFs): "No fields were automatically detected. Please add fields manually."

This is a review step, not silent auto-accept.

### Task 2.3 — Assign submitters to detected signature fields

Once fields are placed, automatically assign each signature/initial/date field to the correct submitter based on position in the document:
- Counterparty signature fields (identified by position near "Counterparty", "Client", "Signed by" labels) → assigned to Stage 2 submitter
- IG signature fields (near "Ignition Group", entity name labels) → assigned to Stage 1 submitter (CEO/COO)
- Approval fields on the CAF itself → handled separately by CafSubmissionCreator (already built)

This requires the LLM: after field detection, post the detected field positions + surrounding text labels to ContractParser (extended prompt) to classify each field's intended signatory. Return a classification per field — the wizard auto-assigns but shows it for review.

### Task 2.4 — Fallback for scanned/image PDFs

If `build_text_runs` returns empty (image PDF) AND the ONNX model fails to detect fields (no confidence), show a clear UI state:
> "This appears to be a scanned document. Automatic field detection is not available. Please use the field editor to place signing fields manually."

**Gates:** All 5.

---

## Sprint 2.5 — Contract Family Model (~6h)

**Goal:** The lightweight linking model that lets legal ops associate related CafWorkflows (e.g. link an addendum to its MSA, or a SOW to a master agreement). This is a prerequisite for Sprint 3 — GCinmyPOCKET needs it for cross-workflow context assembly.

**Note:** The `contract_family_members` migration is defined in Sprint 3 Task 3.3 for continuity, but it must be executed in Sprint 2.5 so the table exists. Run the `contract_family_members` migration from Sprint 3.3 as part of this sprint.

### Task 2.5.1 — ContractFamilyMember model

```ruby
# app/models/contract_family_member.rb
class ContractFamilyMember < ApplicationRecord
  belongs_to :caf_workflow
  belongs_to :linked_workflow, class_name: 'CafWorkflow', optional: true

  validates :document_name, presence: true
  validates :linked_workflow_id, uniqueness: { scope: :caf_workflow_id }, allow_nil: true

  ROLES = %w[master schedule sow addendum nda].freeze
  validates :role, inclusion: { in: ROLES }, allow_nil: true
end
```

Add to `CafWorkflow`:
```ruby
has_many :contract_family_members, dependent: :destroy
has_many :linked_workflows, through: :contract_family_members
```

### Task 2.5.2 — Admin UI: Related Agreements panel

Under `/legal_ops/workflows/:id` — add a "Related Agreements" collapsible panel (Turbo Frame):
- Search existing CafWorkflows by title or counterparty name (Turbo stream, live search)
- Add with role (dropdown: MSA / SOW / Schedule / Addendum / NDA) and reorderable position
- Remove existing links (with confirmation)
- Auto-suggestion banner: if `parsed_contract_data['amends_or_relates_to']` is populated, show:
  > "Extraction suggests this document relates to: [name]. Link it?"
  — one-click adds it as a member with role pre-filled from the array

### Task 2.5.3 — RSpec

- ContractFamilyMember validates uniqueness of linked_workflow per caf_workflow
- Auto-suggestion banner renders when `amends_or_relates_to` present in `parsed_contract_data`
- Removing a member destroys the record and re-renders the panel via Turbo

**Gates:** All 5.

---

## Sprint 3 — GCinmyPOCKET (Pillar 6, ~8h)

**Goal:** An AI general counsel assistant available to internal IG signers (Stage 0 and Stage 1 only) within the signing form. Answers questions about the contract and related agreements. Counterparty signers (Stage 2) see nothing.

### Task 3.1 — Chat system prompt

Create `config/prompts/gcip_chat_v1.md`:

```markdown
You are GCinmyPOCKET, the AI assistant for Ignition Group's Legal and Compliance team.

You assist internal IG signers (approvers and executives) who are reviewing agreements before signing. You have access to the documents in this signing envelope and any related agreements that have been linked.

Rules:
- Answer based solely on the provided documents. Do not speculate.
- When an addendum or SOW changes a term from a parent agreement, quote both the original and the amended provision and explain the difference clearly.
- Cite specific clauses when referencing document text (e.g. "Clause 7.3 of the MSA states...").
- If asked about the internal approval process for this agreement, explain the required stages based on the approval data provided.
- Answers should be plain English, executive-level. 3-5 sentences unless more detail is genuinely needed.
- Do not give legal advice. If the question requires legal interpretation beyond reading the document, say so and recommend Craig Lawrence reviews it.
- You are NOT available to counterparty or external signers. If you receive a question from an external signer, do not answer and return an error.

Context: You are operating within IGSIGN, Ignition Group's internal contract execution platform. The ECT Act (South Africa) governs electronic signatures.
```

### Task 3.2 — ContractChatService

Create `app/services/contract_chat_service.rb`:

```ruby
# IGSIGN — GCinmyPOCKET backend.
# Available to Stage 0 (approvers) and Stage 1 (IG executive) signers ONLY.
# Stage 2 counterparty submitters must never receive a response.
class ContractChatService
  SYSTEM_PROMPT_PATH = Rails.root.join('config/prompts/gcip_chat_v1.md')
  MAX_CONTEXT_CHARS = 60_000

  def self.answer(question:, caf_workflow_id:, submitter:, conversation_history: [])
    new(question:, caf_workflow_id:, submitter:, conversation_history:).answer
  end

  def initialize(question:, caf_workflow_id:, submitter:, conversation_history:)
    @question = question
    @caf_workflow_id = caf_workflow_id
    @submitter = submitter
    @conversation_history = conversation_history
  end

  def answer
    return { error: 'Not available' } unless internal_signer?
    return { error: 'AI_API_KEY not configured' } if ENV['AI_API_KEY'].blank?

    context = assemble_context
    return { error: 'No document text available for this agreement.' } if context.blank?

    result = call_llm(build_messages(context))
    log_exchange(result)
    result
  rescue StandardError => e
    Rails.logger.error("[IGSIGN] ContractChatService error: #{e.message}")
    { error: 'An error occurred. Please try again.' }
  end

  private

  # Returns true only for Stage 0 and Stage 1 submitters.
  # Stage 2 (counterparty) is rejected at service level — do not rely solely on controller gating.
  def internal_signer?
    stage = @submitter.submission&.caf_stage
    stage&.stage_type&.in?(%w[internal executive]) || false
  end

  def assemble_context
    workflow = CafWorkflow.find_by(id: @caf_workflow_id)
    return '' unless workflow

    texts = []

    # 1. Envelope documents — non-internal only (internal CAF summary not included even for Stage 1)
    #    Stage 0/1 signers see agreement text, not IG internal approval audit data.
    envelope_docs = workflow.caf_stages
                            .includes(caf_stage_documents: { document: :blob })
                            .flat_map { |s| s.caf_stage_documents.where(internal_only: false).map(&:document) }
                            .compact.uniq(&:id)

    envelope_docs.each do |doc|
      text = extract_text(doc)
      texts << "=== #{doc.filename} (this envelope) ===\n#{text}" if text.present?
    end

    # 2. Manually linked related agreements (by legal ops)
    workflow.contract_family_members.includes(:linked_workflow).order(:position).each do |member|
      next unless member.linked_workflow&.parsed_contract_data.present?
      next if member.linked_workflow.parsed_contract_data['error']
      summary = member.linked_workflow.parsed_contract_data['summary']
      texts << "=== #{member.document_name} (#{member.role}) ===\n#{summary}" if summary.present?
    end

    # 3. Other CafWorkflows for the same counterparty company — summary only (not full text)
    if workflow.company_id.present?
      related = CafWorkflow.where(company_id: workflow.company_id)
                           .where.not(id: workflow.id)
                           .where.not(parsed_contract_data: nil)
                           .order(created_at: :desc).limit(5)
      related.each do |r|
        next if r.parsed_contract_data['error']
        summary = r.parsed_contract_data['summary']
        ctype = r.parsed_contract_data['contract_type']
        texts << "=== Prior agreement (#{ctype}) ===\n#{summary}" if summary.present?
      end
    end

    texts.join("\n\n").slice(0, MAX_CONTEXT_CHARS)
  end

  def extract_text(document)
    runs = DocumentMetadatas.build_text_runs(document)
    return '' if runs.blank?
    runs.values.flat_map { |objs| objs.filter_map { |o| o[:text].presence } }.join(' ').squeeze(' ').strip
  rescue StandardError
    ''
  end

  def build_messages(context)
    system = "#{File.read(SYSTEM_PROMPT_PATH)}\n\n--- DOCUMENTS ---\n#{context}"
    history = @conversation_history.last(6).map { |m| { role: m[:role], content: m[:content] } }
    [{ role: 'system', content: system }] + history + [{ role: 'user', content: @question }]
  end

  def call_llm(messages)
    client = Faraday.new(url: ENV['AI_BASE_URL']) do |f|
      f.request :json
      f.response :json
      f.adapter Faraday.default_adapter
      f.headers['Authorization'] = "Bearer #{ENV['AI_API_KEY']}"
      f.headers['HTTP-Referer'] = 'https://igsign.ignitiongroup.co.za'
      f.headers['X-Title'] = 'GCinmyPOCKET'
    end

    response = client.post('chat/completions', {
      model: ENV.fetch('AI_MODEL', 'meta-llama/llama-3.3-70b-instruct:free'),
      messages:,
      temperature: 0.3
    })

    raise "HTTP #{response.status}" unless response.success?
    content = response.body.dig('choices', 0, 'message', 'content')
    raise 'Empty response' if content.blank?
    { answer: content }
  rescue Faraday::Error => e
    { error: "Network error: #{e.message}" }
  end

  def log_exchange(result)
    ChatAuditLog.create!(
      caf_workflow_id: @caf_workflow_id,
      submitter_token_digest: Digest::SHA256.hexdigest(@submitter.slug.to_s),
      signer_role: 'internal',
      question: @question,
      answer: result[:answer],
      error: result[:error]
    )
  rescue StandardError => e
    Rails.logger.warn("[IGSIGN] ChatAuditLog write failed: #{e.message}")
    # Do not re-raise — audit log failure must not block the answer
  end
end
```

### Task 3.3 — Migrations

**Migration 1: chat_audit_logs**
```ruby
create_table :chat_audit_logs do |t|
  t.references :caf_workflow, null: false, foreign_key: true
  t.string :submitter_token_digest, null: false
  t.string :signer_role
  t.text :question, null: false
  t.text :answer
  t.string :error
  t.timestamps
end
add_index :chat_audit_logs, [:caf_workflow_id, :created_at]
```

**Migration 2: contract_family_members** (lightweight related-doc linker)
```ruby
create_table :contract_family_members do |t|
  t.references :caf_workflow, null: false, foreign_key: true       # the agreement being signed
  t.references :linked_workflow, foreign_key: { to_table: :caf_workflows }  # related agreement
  t.string :document_name, null: false
  t.string :role   # 'master', 'schedule', 'sow', 'addendum', 'nda'
  t.integer :position, default: 0
  t.timestamps
  t.index [:caf_workflow_id, :linked_workflow_id], unique: true
end
```

### Task 3.4 — Chat controller and route

```ruby
# config/routes.rb
scope :internal do
  post 'gcip/chat', to: 'gcip/chat#create', as: :gcip_chat
end
```

`app/controllers/gcip/chat_controller.rb`:
- Authenticates submitter token (mirror SubmitFormController auth pattern)
- Verifies token belongs to a submission in the specified `caf_workflow_id` (403 if not)
- Calls `ContractChatService.answer`
- Rate limit: 20 requests/minute per token via IgsignSigningThrottleMiddleware

### Task 3.5 — Linked agreements admin UI

Under `/legal_ops/workflows/:id` — a "Related Agreements" panel:
- Search existing CafWorkflows (by title, counterparty, or contract type)
- Add as a linked member with a role (MSA, SOW, Schedule, Addendum) and position
- Remove links
- Show auto-suggestion banner if `amends_or_relates_to` is populated from parsing

### Task 3.6 — RSpec

- `ContractChatService` — internal_signer? returns false for Stage 2, service returns `{ error: 'Not available' }` without calling LLM
- Context assembly — internal_only documents excluded
- ChatAuditLog written on successful answer
- ChatAuditLog failure does not raise

**Gates:** All 5.

---

## Sprint 4 — GCinmyPOCKET UI (Signing Form, ~6h)

**Goal:** Floating chat panel on the signing form — visible ONLY to Stage 0 and Stage 1 submitters.

### Task 4.1 — Stage gate in the signing form view

In `app/views/submit_form/show.html.erb`, render the GCinmyPOCKET panel ONLY when:
```ruby
AI_API_KEY present AND submitter.submission.caf_stage.stage_type.in?(['internal', 'executive'])
```

For Stage 2 (counterparty) submitters, the panel is not rendered at all — no element, no hidden div, nothing. The counterparty signing experience is identical to stock DocuSeal.

### Task 4.2 — Stimulus controller `gcip_controller.js`

`app/javascript/controllers/gcip_controller.js`:
- Toggle panel open/close (floating button, bottom-right)
- Submit question on Enter or Send button click
- Store conversation history in controller state
- POST to `/internal/gcip/chat` with question + history array
- Render answer tokens as they stream (if streaming implemented) or show spinner until full response
- Scroll to bottom after each message
- Warn on mount: "Your conversation will be cleared if you refresh this page."

### Task 4.3 — Chat panel partial

`app/views/gcip/_panel.html.erb`:
- Floating panel, fixed bottom-right, z-index above signing form
- IG Arctic Black (`#0B1722`) header: "GCinmyPOCKET" + close button
- Message thread (scrollable), user messages right-aligned, bot messages left-aligned
- Input + Send button (IG Green `#00C853` on active state)
- Footer: "For legal advice on interpretation, consult your legal team."
- Accessibility: ESC closes, tab-navigable, focus trapped while open, responsive on mobile

### Task 4.4 — Manual browser verification (required)

On 172.30.0.30:
1. Sign in as an internal Stage 0/1 user (Craig or Sean) → chat panel appears
2. Sign as a Stage 2 counterparty → chat panel absent entirely
3. Ask a question → answer returned in <15 seconds
4. Conversation history maintained across 3 turns
5. Signing form still completes correctly with panel open

**Gates:** All 5 + Task 4.4.

---

## Sprint 5 — Contracts Dashboard (Pillar 5, ~10h)

**Goal:** A legal ops dashboard giving a live view of IG's contract exposure — by entity, by counterparty, by risk profile — drawn from `caf_workflows` + `parsed_contract_data`.

### Task 5.1 — Dashboard route and controller

`/legal_ops/dashboard` — new action on an existing or new LegalOps controller. Role-gated to internal users only.

### Task 5.2 — Data aggregation

All dashboard queries use **native columns** — not jsonb. This is why Sprint 0's migration and `ContractParsingJob` write to native columns: the dashboard never queries `parsed_contract_data` directly.

```ruby
# All of these use indexed native columns — fast, type-safe
CafWorkflow.where(account_id: current_account)
           .where(status: 'active')
           .group(:entity).count                            # by IG entity

CafWorkflow.where(expiry_date: Date.today..90.days.from_now)
           .order(:expiry_date)                             # expiring soon

CafWorkflow.where(auto_renewal: true)
           .where(expiry_date: ..90.days.from_now)          # auto-renewal at risk

CafWorkflow.where(expiry_date: nil)
           .where.not(status: 'draft')                      # evergreen / unknown
```

`agreement_value` is a string and cannot be summed directly — display total count of agreements with values, and flag those without. Do not attempt to sum string values; that produces garbage. A future sprint can add a numeric `agreement_value_cents` column if contract value summation is required.

**Data quality indicators on dashboard rows:**
- Green dot: all dashboard fields have provenance 'ai' or 'manual'  
- Amber dot: some dashboard fields null — click opens `/legal_ops/workflows/:id/contract_data` to complete
- Red dot: parsing failed (error key in `parsed_contract_data`) — click opens manual fallback form

### Task 5.3 — Dashboard view

`app/views/legal_ops/dashboard.html.erb`:
- Stat cards: total active, expiring soon, auto-renewal at risk, total estimated value
- Table: agreements sorted by expiry date, columns: entity, counterparty, type, value, expiry, auto-renewal, stage
- Filter bar: by entity, by counterparty type (customer/supplier), by contract type, by stage status
- Expiry alerts: red for <30 days, amber for 30-90 days
- Click-through to individual workflow

Use Hotwire/Turbo for filter interactions — no full page reloads.

### Task 5.4 — Risk indicators

Derived from native columns — fast, no jsonb parsing at query time:

```ruby
# In CafWorkflow model
def risk_flags
  flags = []

  # Liability
  flags << 'No liability cap' if liability_cap.blank? || liability_cap == 'Not Included'
  flags << 'No indirect/consequential exclusion' if liability_exclusion_indirect == 'Not Included'

  # Term and renewal
  flags << 'Auto-renewal — notice period under 30 days' if auto_renewal? && notice_period_days.present? && notice_period_days < 30
  flags << 'Auto-renewal — no notice period stated' if auto_renewal? && notice_period_days.nil?
  flags << 'Expired' if expiry_date.present? && expiry_date < Date.today && status != 'complete'
  flags << 'No expiry date' if expiry_date.nil? && !auto_renewal?

  # Governing
  flags << 'No governing law' if governing_law.blank?
  flags << 'No dispute resolution clause' if dispute_resolution == 'Not Included'

  # Commercial
  flags << 'Late payment terms' if payment_terms_days.present? && payment_terms_days > 60 && commercial_relationship == 'supplier'
  flags << 'IG locked in exclusively' if exclusivity == 'IG exclusive (locked in)'

  # Operational
  flags << 'Subcontracting permitted without consent' if subcontracting.present? &&
    subcontracting.downcase.include?('without consent')
  flags << 'No data protection clause' if data_protection_clause == 'Not Included'
  flags << 'Change of control — no provision' if change_of_control == 'No provision'
  flags << 'Assignment — no provision' if assignment == 'No provision'

  flags
end
```

Show as colour-coded badges on dashboard rows. These are prompts for legal review — not automated compliance determinations. Clicking a flag badge opens the workflow detail.

**Data completeness score:** Each agreement gets a completeness percentage based on how many of `CafFieldSchema.dashboard_fields` have non-null values with provenance. Show as a progress bar on the dashboard row — a visual cue for legal ops to know which agreements need data completion before the dashboard is reliable.

**Gates:** All 5.

---

## Sprint 6 — Azure Migration (Pilot Sunset, 2026-08-24)

**Goal:** Replace OpenRouter with Azure OpenAI (zero-data-retention, POPIA-compliant). No changes to Rails interfaces — only the LLM call layer changes.

### Task 6.1 — Extend IgsignLlmClient for Azure OpenAI

`IgsignLlmClient` was created in Sprint 0. This task adds Azure OpenAI support to it — no caller changes required.

### Task 6.2 — Replace OpenRouter with Azure OpenAI

Azure OpenAI is OpenAI-compatible. Only the endpoint and auth header change.

New env vars:
- `AZURE_OPENAI_ENDPOINT`
- `AZURE_OPENAI_KEY`
- `AZURE_OPENAI_DEPLOYMENT` (e.g. `gpt-4o`)

`IgsignLlmClient` reads these when present and falls back to `AI_BASE_URL`/`AI_API_KEY` (OpenRouter) otherwise. This allows side-by-side testing before full cutover.

### Task 6.3 — Smoke test update

Update `rake igsign:smoke_test` to check for Azure vars when `AZURE_OPENAI_ENDPOINT` is set, and verify the LLM client connects successfully.

---

## Sequencing Summary

```
Sprint 0   (now,      ~8h): CafFieldSchema + IgsignLlmClient + migrations + parsing pipeline + manual fallback form
Sprint 0.5 (week 1,   ~8h): CAF redesign — Grover PDF engine + redesigned templates with all register fields
Sprint 1   (week 2,   ~6h): CAF fields pre-filled from AI extraction → requestor reviews, not types
Sprint 2   (week 3,   ~8h): Auto field placement — signing fields detected and placed automatically
Sprint 2.5 (week 4,   ~6h): Contract Family model + admin UI → cross-workflow context (prerequisite for Sprint 3)
Sprint 3   (week 4,   ~8h): GCinmyPOCKET service (internal signers only)
Sprint 4   (week 5,   ~6h): GCinmyPOCKET UI on signing form (Stage 0/1 only, zero exposure to Stage 2)
Sprint 5   (week 6,  ~10h): Contracts dashboard → register view with all CafFieldSchema fields
Sprint 6   (sunset):        Azure OpenAI migration → POPIA-compliant production LLM
```

---

## Full Functional Outcomes — What IGSIGN Does When Complete

### After Sprint 0
Legal ops uploads a contract. Within ~30 seconds, every field from the contracts register is extracted — contract type, parties, term dates, period, auto-renewal, notice period, cancellation rights (convenience and breach), liability exclusions and aggregate cap, data protection clause, change of control classification, SOW value, minimum spend, pricing structure, IP ownership, governing law, material risks, and a structured high-level summary covering commercial purpose, costing, and key risk.

Every value is a distilled plain-English summary — not a quoted clause. If a provision is absent from the contract, the field reads "Not Included" rather than blank.

Legal ops can open the contract data form for any agreement, see every field with its AI or Manual provenance badge, correct any value, and save. Saved values write to indexed native columns that the dashboard queries. If parsing failed entirely, the same form is presented empty — there is no dead end. Re-parsing overwrites only AI-sourced fields, preserving anything entered manually.

### After Sprint 0.5
The CAF is a professional, IG-branded legal document rendered by Chrome headless via Grover. DM Sans renders correctly. Section headers are Arctic Black with green accents. "Not Included" provisions display in muted grey. Missing liability caps and data protection clauses display in red — visual risk flags that a CEO reviewing the CAF will immediately notice. The signing page has a proper page break. The CAF looks like something you would send to a board.

### After Sprint 1
The requestor uploads a contract and the CAF wizard fields — mandate description, agreement purpose, agreement value, payment terms, counterparty name, key risks — are **pre-populated from the AI extraction**. The requestor reviews and adjusts rather than typing everything from scratch. Where the contract references a parent agreement (e.g. an addendum), the system suggests linking it to the existing workflow for that MSA. The CAF, when generated, contains accurate pre-filled data rather than relying entirely on the requestor's manual input.

### After Sprint 2
When a contract PDF is uploaded, **signing fields are automatically placed** at the correct positions — signature blocks, initial fields, date fields, and text boxes for name and address — using DocuSeal's ONNX ML model. The requestor sees a field review step showing all detected fields, can accept them or open the editor to adjust. Each field is pre-assigned to the correct submitter (counterparty vs IG signatory) based on the label context around it. Scanned PDFs that cannot be auto-detected surface a clear prompt to add fields manually.

### After Sprint 3 and Sprint 4
**GCinmyPOCKET is live inside the signing form** for all internal IG signers — approvers in Stage 0 and executives in Stage 1. A signer about to approve or sign can ask: *"What does clause 12.3 of this SOW change from the original MSA payment terms?"* and receive a plain-English answer that quotes both documents side by side. The bot knows: the documents in the current envelope, any related agreements that legal ops has linked (MSA, prior SOWs, schedules), and summaries of prior agreements with the same counterparty. Every question and answer is logged to `chat_audit_logs` with a digest of the document context used — creating a tamper-evident record for dispute resolution. **Counterparty signers (Stage 2) see a clean DocuSeal signing form with no chatbot and no IG internal information.**

### After Sprint 5
Legal ops has a **live contracts dashboard** showing: all active IG agreements by entity and counterparty, agreements expiring in the next 90 days, auto-renewal agreements at risk, total estimated contract value, and risk indicators (missing liability cap, unusually long payment terms, evergreen without expiry). Clicking any row opens the full workflow. The dashboard is the starting point for every legal ops review — it replaces ad-hoc spreadsheet tracking.

### After Sprint 6
All contract text processed through IGSIGN is handled by **Azure OpenAI within IG's Microsoft tenant**. Zero data retention. No third-party exposure. POPIA-compliant for live client contracts. The OpenRouter dependency is fully removed. IGSIGN is ready for production use with external counterparties.

---

## How to Use This Document in Claude Code

Start each session with:

```
Read CLAUDE.md and docs/IGSIGN_AI_SPRINT_PLAN.md.
Then execute [Sprint 0 / Sprint 1 / Sprint 2 / Sprint 3 / Sprint 4 / Sprint 5] in full.
Use the agents in .claude/agents/ as directed. Apply all quality gates before reporting done.
```

One sprint per session. Do not skip gates.

---

## Backlog — Not in Pilot Scope

### BU-Specific CAF Templates

Each business unit (CX, IFS, Spot Connect, etc.) has distinct commercial models with different material fields. A CX deal captures per-agent rate, minimum agent commitment, ramp schedule. An IFS deal captures different things. The current CAF is a single long-form template with generic commercial fields.

**Future work:** Per-BU CAF variants driven by the same `CafFieldSchema` pattern — a `bu_fields` key on each field definition that lists which BUs the field applies to, plus BU-specific sections in the CAF template that are conditionally rendered. The `entity` field on `CafWorkflow` already identifies the IG entity, which maps to a BU.

Craig to provide BU-specific payment type detail for CX before this sprint is specced. Do not build until that input is received.

**Earliest sensible sprint:** After Sprint 0.5 (CAF redesign complete) — BU variants are an extension of the redesigned templates.

---

## Privacy & Compliance

| Phase | Data sent to | Risk |
|---|---|---|
| POC (OpenRouter) | Meta Llama via OpenRouter — US-hosted third party | Acceptable for internal IG agreements during pilot. Not acceptable for live client contracts. |
| Azure (Sprint 6) | Azure OpenAI in IG's Microsoft tenant | Zero data retention, stays within IG boundary, POPIA-compliant |

Do not use OpenRouter for client contracts containing counterparty personal information. The Azure migration (Sprint 6) is a hard requirement before external rollout.
