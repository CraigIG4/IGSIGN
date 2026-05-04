# IGSIGN — Product Specification

**Version:** 0.1 (May 2026)
**Owner:** Craig Lawrence (CLO, Ignition Group)
**Codebase:** Fork of [DocuSeal](https://github.com/docusealco/docuseal) (AGPL-3.0)
**Repo:** [github.com/CraigIG4/docuseal](https://github.com/CraigIG4/docuseal)

> Internal e-signature platform replacing DocuSign / Cygnature for Ignition Group. ECT Act 25 of 2002 SES-grade for ~99% of flows. Self-hosted on IG infrastructure (intended: AWS af-south-1 or on-prem). AGPL-3.0 internal use only — no external counterparty access at the application level.

---

## 1. Why IGSIGN exists

DocuSign is expensive at IG's volume, doesn't model IG's CAF-then-strip workflow cleanly, and forces IG into per-envelope billing. IGSIGN is a custom build that:

- **Eliminates per-envelope cost** — flat infrastructure spend, no envelope counting.
- **Models the Contract Approval Form (CAF) workflow natively** — internal CAF approval chain runs first, CAF is *removed* from the envelope before the document is sent to the counterparty.
- **Separates internal from external signing** — different signer sets, different document subsets, same envelope identity.
- **Stays inside IG-controlled infrastructure** — POPIA-aligned data residency, no third-party SaaS.

Legal frame: **ECT Act SES** is sufficient for ~99% of IG's documents (NDAs, MSAs, SOWs, employment letters, vendor contracts). AES (Advanced Electronic Signature) is **not** in scope for v1 — IG never executes documents requiring it (suretyships, certain POAs, alienation of land instruments).

---

## 2. Core entities

DocuSeal's existing model:

- **Account** — the IG tenant
- **User** — internal IG staff (Legal, Finance, Executive)
- **Template** — reusable document with field placements (signature, initial, date, text, dropdown, attachment, formula)
- **Submission** — an instance of a template sent for signing
- **Submitter** — a signer (internal user or external email)

IGSIGN extensions (see §6 for the data-model design):

- **Stage** — a phase of an envelope (e.g., Stage 1: Internal CAF approval; Stage 2: External counterparty signing)
- **StageDocument** — a join row linking a document to one or more stages, with `internal_only` flag
- **ApprovalMatrix** — the rules table mapping document type → required signer roles per stage
- **AuditEntry** — chained, hash-sealed event log for evidentiary integrity

---

## 3. Core use cases (worked end-to-end)

### Use case 1 — NDA (single stage, single signer)

**Document:** Mutual NDA between IG and Counterparty X

**Flow:**
1. CLO uploads the NDA, places signature fields for IG signatory and Counterparty signatory.
2. CLO sends — both parties get magic-link emails in parallel.
3. Counterparty signs (drawn / typed / uploaded image).
4. CLO signs.
5. Envelope sealed; PDF + audit JSON archived.

**Signer set:** CLO + counterparty signatory (per Craig's matrix).

**No CAF required** — NDAs are below the CAF threshold.

### Use case 2 — Counterparty contract with CAF (multi-stage, strip-and-forward)

**Documents:** Master Services Agreement + CAF (Contract Approval Form)

**Flow:**
1. **Originator (Legal)** uploads the **Draft MSA** + **CAF**, marks the CAF as `internal_only`.
2. Legal places signature/approval fields on both:
   - On CAF: signature blocks for **Legal, CFO, CEO** (sequential, ordered)
   - On MSA: signature blocks for **CEO** (IG side) + **Counterparty signatory** + optional **Counterparty witness**
3. Legal sends — envelope enters **Stage 1: Internal CAF Approval**.
4. **Stage 1 routing (ordered):**
   - Email to Legal → Legal opens, reviews CAF + MSA, signs CAF.
   - Email to CFO → CFO opens, reviews CAF + MSA, signs CAF.
   - Email to CEO → CEO opens, reviews CAF + MSA, signs CAF.
5. **Stage 1 → Stage 2 transition:** CAF marked `internal_only` is **stripped** from the envelope's outgoing manifest. CAF persists on the audit trail with hash, but is not delivered to external recipients. CEO additionally signs the **MSA** at this transition (or at start of Stage 2, configurable per template).
6. **Stage 2: Counterparty signing (parallel or ordered, configurable):**
   - Email to Counterparty signatory → signs the MSA.
   - (Optional) Email to Counterparty witness → signs as witness.
7. **Stage 3 (optional countersignature):** Returns to CEO for final stamp on counter-signed copy. Often unnecessary because CEO already signed in Stage 1.
8. Envelope sealed; final PDF (MSA only — no CAF) + audit JSON (full chain including stripped-CAF event) archived.

**Approver set per Craig's matrix:**
- CAF approvers (Stage 1, ordered): **Legal → CFO → CEO** (every CAF)
- Document signer (Stage 2, IG side): **CEO + COO** (for contracts) or **CLO** (for NDAs)
- Counterparty signers (Stage 2): variable, configured per envelope

### Use case 3 — Multi-document envelope with per-recipient subsets

**Scenario:** IG sends a deal pack — cover letter, MSA, Schedule A (commercial terms), Schedule B (technical specs). The Counterparty's commercial lead should see all of it; their technical lead should only see cover + Schedule B.

**Flow:**
1. Legal uploads all four documents.
2. Per recipient, Legal toggles which documents are visible to them.
3. Each recipient's signing portal shows only their assigned subset.
4. Audit trail records who saw what.

This is **first-class** in IGSIGN — DocuSign requires CLM (separate, expensive SKU) for this; in IGSIGN it's a per-recipient document visibility flag on the StageDocument join.

---

## 4. UI / UX principles

IGSIGN is a **B2B legal-tech tool used daily by senior staff under time pressure**. Design priorities, in order:

1. **Clarity** — every screen has one obvious next action.
2. **Density** — list views show enough information that the user doesn't have to click in to know what an item is.
3. **Speed** — keyboard-first navigation, optimistic UI, no animations longer than 150ms.
4. **Trust** — typography, spacing, and chrome look like legal infrastructure (think: Stripe Atlas, Linear, Pleo), not consumer SaaS.
5. **Accessibility** — WCAG 2.1 AA. CEOs use this on tablets, on planes, in dim hotel rooms.

### Visual language

- **Type:** Inter (system fallback `system-ui, -apple-system, sans-serif`). Body 15–16px, dense tables 14px, page titles 24–28px, hero numbers 32–40px.
- **Colour:**
  - Primary brand: **IG navy** `#1a2332` (chrome, headers, primary buttons)
  - Mid navy: `#2e3d54` (hover states, secondary surfaces)
  - Accent: `#3b82f6` (links, highlights, focus rings)
  - Surfaces: white `#ffffff`, light grey `#f4f6f8`, divider `#e5e9ec`
  - Body text: near-black `#0f1419`
  - Status: success `#16a34a`, warning `#d97706`, danger `#dc2626`
- **Spacing:** 4px base grid. Page gutter 24–32px desktop, 16px mobile. Card padding 24px.
- **Corners:** 8px on cards, 6px on buttons/inputs, 999px on pills/avatars.
- **Shadows:** sparing. `0 1px 3px rgba(15,20,25,0.08)` for cards. No depth-y skeumorphism.
- **Iconography:** stroke 1.5px, 20px default, Lucide-style (DocuSeal already uses similar).

### Component priorities for v1 polish

| Component | Current state | Target |
|---|---|---|
| Navbar | Logo + "DocuSeal" middle + settings | Logo + "Ignition Group · e-Signing Portal — IGSIGN" + settings + avatar |
| Empty states | Plain dashed boxes | Iconic, instructive — "Upload your first document to get started" with a one-line how-it-works hint |
| Buttons | DaisyUI defaults | Primary = navy bg + white text + 6px radius + 600 weight; Secondary = outline; Destructive = red text + outline |
| Tables / lists | DaisyUI table | Dense, alternating-row, sortable column headers, sticky header on long lists |
| Forms | DaisyUI inputs | Floating labels OR top-aligned labels with 13px label + 15px input; error messages inline with red icon |
| Document viewer (signing screen) | DocuSeal's current viewer | Keep DocuSeal's PDF viewer; add a **stage progress strip** at top showing CAF → Internal Approval → CEO → Counterparty |

### Navbar v2 (this commit)

```
[ IG-hex IGSIGN ]   [ Ignition Group ]                     [ Settings  CL ]
                    [ e-SIGNING PORTAL — IGSIGN ]
```

Logo left, two-line wordmark immediately right, settings + avatar far right.

---

## 5. Multi-signing pathways

Per stage, the sender chooses one of three routings:

1. **Ordered** — A then B then C. B doesn't get notified until A completes. Used for: CAF approval (Legal → CFO → CEO).
2. **Parallel** — A, B, and C all get notified simultaneously. Used for: counterparty signatory + witness in same stage.
3. **Hybrid** — `(A and B in parallel) then C`. Used rarely; supports e.g. dual-side commercial leads sign in parallel, then both CEOs counter-sign.

Routing is configured **per stage**, not per envelope. So a single envelope can have:
- Stage 1: ordered (internal CAF approval)
- Stage 2: parallel (counterparty signing)
- Stage 3: ordered (CEO counter-sign)

DocuSeal's existing `Submitter.signing_order` field models this for a single-stage envelope. IGSIGN's `Stage` table extends it.

---

## 6. CAF inclusion — data model design

### New tables (Rails migration)

```
# Stage: a phase within an envelope (1..N)
class CreateStages < ActiveRecord::Migration[8.1]
  def change
    create_table :stages do |t|
      t.references :submission, null: false, foreign_key: true
      t.integer :position, null: false           # 1, 2, 3...
      t.string  :name, null: false               # "Internal CAF Approval", "Counterparty Signing"
      t.string  :routing, null: false            # "ordered" | "parallel" | "hybrid"
      t.string  :status, null: false, default: 'pending'  # pending|active|completed|skipped
      t.boolean :strip_internal_on_complete, default: false
      t.datetime :completed_at
      t.timestamps
    end
    add_index :stages, [:submission_id, :position], unique: true
  end
end

# StageDocument: join — which documents belong to which stages, with internal flag
class CreateStageDocuments < ActiveRecord::Migration[8.1]
  def change
    create_table :stage_documents do |t|
      t.references :stage, null: false, foreign_key: true
      t.references :submission_document, null: false, foreign_key: true
      t.boolean :internal_only, null: false, default: false
      t.timestamps
    end
    add_index :stage_documents, [:stage_id, :submission_document_id], unique: true
  end
end

# Per-recipient document visibility (for Use Case 3)
class CreateSubmitterDocumentVisibilities < ActiveRecord::Migration[8.1]
  def change
    create_table :submitter_document_visibilities do |t|
      t.references :submitter, null: false, foreign_key: true
      t.references :submission_document, null: false, foreign_key: true
      t.boolean :visible, null: false, default: true
      t.timestamps
    end
    add_index :submitter_document_visibilities, [:submitter_id, :submission_document_id], unique: true,
              name: 'idx_submitter_doc_visibility_unique'
  end
end

# ApprovalMatrix — declarative rules: document_type -> required role chain per stage
class CreateApprovalMatrices < ActiveRecord::Migration[8.1]
  def change
    create_table :approval_matrices do |t|
      t.references :account, null: false, foreign_key: true
      t.string :document_type, null: false           # "nda" | "contract" | "msa"
      t.json   :stages, null: false                  # [{ name:, routing:, required_roles: [...] }, ...]
      t.timestamps
    end
    add_index :approval_matrices, [:account_id, :document_type], unique: true
  end
end
```

### Strip-on-complete behaviour

When a stage with `strip_internal_on_complete = true` finishes:

1. For the next stage's outgoing email, the document manifest excludes any `submission_document` joined to a prior `stage_document` with `internal_only = true`.
2. The audit trail records a `documents_stripped` event with the SHA-256 hash and filename of the stripped document.
3. The stripped document is **not deleted** — it remains on the envelope, accessible to internal users with the `view_internal_documents` permission. Only the *outgoing manifest* to external recipients excludes it.

### Approval matrix seed data (IG defaults per Craig)

```ruby
ApprovalMatrix.seed do |s|
  s.document_type = 'nda'
  s.stages = [
    { name: 'IG Signing',          routing: 'parallel', required_roles: ['CLO'] },
    { name: 'Counterparty Signing', routing: 'parallel', required_roles: [:counterparty] }
  ]
end

ApprovalMatrix.seed do |s|
  s.document_type = 'contract'
  s.stages = [
    { name: 'Internal CAF Approval', routing: 'ordered', required_roles: ['Legal', 'CFO', 'CEO'], strip_internal_on_complete: true },
    { name: 'Counterparty Signing',  routing: 'parallel', required_roles: [:counterparty, :counterparty_witness] },
    { name: 'CEO Countersign',       routing: 'ordered', required_roles: ['CEO'], optional: true }
  ]
end
```

---

## 7. Multi-document upload UX

The "Upload a New Document" empty state in DocuSeal is single-file. IGSIGN extends it to multi-file in one of two patterns:

### Pattern A: drag multiple files → one envelope, separate documents

User drags `Cover.pdf`, `MSA.pdf`, `Schedule_A.pdf` simultaneously. The "New Submission" screen lists all three as separate documents. Per document, the user can:
- Place fields independently
- Toggle `internal_only` (with a clear "Stripped before external send" badge)
- Toggle visibility per recipient

### Pattern B: combined PDF with page-level internal flags

User uploads a single PDF that contains both the CAF (pages 1–3) and the MSA (pages 4–28). The user marks pages 1–3 as `internal_only` via a page-range selector. On strip, those pages are removed from the outgoing PDF (handled by `hexapdf` gem already in DocuSeal).

**v1 ships Pattern A only.** Pattern B is a phase-2 nice-to-have because page-range stripping is more complex and most IG flows have CAF-as-separate-PDF anyway.

---

## 8. Authentication & authorisation

### Internal users (IG staff)

- **Microsoft Entra ID (Azure AD) SSO via OIDC** — no IG passwords stored in IGSIGN.
- IG roles map to IGSIGN roles via Entra group membership:
  - `IGSIGN-Admin` → admin
  - `IGSIGN-Legal` → legal (can originate envelopes, sign CAFs)
  - `IGSIGN-Finance` → finance (CFO sign rights)
  - `IGSIGN-Exec` → executive (CEO/COO sign rights)
  - default IG users → reader

### External signers (counterparties)

- **Magic-link** sent to email. No password.
- Optional second factor:
  - Email OTP (default for low-risk docs)
  - SMS OTP (for high-risk; uses Clickatell for ZA-local delivery)
- Link expiry configurable per envelope; default 14 days; one-click reissue.

---

## 9. Email — sender identity and deliverability

- **From address:** `IGSIGN@ignitiongroup.co.za`
- **Display name:** `Ignition Group e-Signing` or per-template (e.g., `Craig Lawrence at Ignition Group`)
- **DNS records required (one-time, IT to configure):**
  - SPF: include `_spf.<provider>` of chosen relay (Postmark or AWS SES)
  - DKIM: signed by the relay
  - DMARC: `v=DMARC1; p=quarantine; rua=mailto:dmarc@ignitiongroup.co.za`
- **Suggested provider:** Postmark for transactional reliability, or SES if IG is already AWS-native. Postmark wins on inbox placement for legal mail; SES wins on cost and AWS integration.

---

## 10. Audit trail (evidentiary integrity)

Every state-changing event is appended to a chained log:

```
{
  "event": "submitter_signed",
  "envelope_id": "abc123",
  "stage_id": 2,
  "actor_id": "submitter_456",
  "actor_email": "ceo@counterparty.com",
  "actor_ip": "203.0.113.42",
  "user_agent": "Chrome/142.0 macOS",
  "geo_approx": "Cape Town, ZA",
  "timestamp_utc": "2026-05-04T08:32:11Z",
  "doc_hash_sha256": "...",
  "prev_audit_hash": "...",       # links to prior event
  "this_audit_hash": "...",       # SHA-256 of this event payload
  "platform_signature": "..."     # signed by IGSIGN's audit key (Vault/KMS)
}
```

The chain forms a **Merkle-style log** — tamper anywhere and subsequent hashes break. Exportable as JSON (machine-readable) and as a "Certificate of Completion" PDF (court-readable, attached to the sealed envelope).

ECT Act §13(1)–(3) integrity requirements satisfied: document is reliably linked to signatory (auth + IP + timestamp + signature), tamper-evident (cryptographic chain).

---

## 11. Build phases

| Phase | Outcome | Effort |
|---|---|---|
| **0 — Bootstrap** ✅ | DocuSeal forked, dev env up, baseline IGSIGN branding | Done |
| **1 — Brand v2** | Strong navbar, button styles, empty states, full IG palette pass | 1–2 days |
| **2 — CAF stage engine** | Stage / StageDocument / ApprovalMatrix migrations, model code, basic stage transitions | 4–6 days |
| **3 — Multi-doc envelope** | Drag-and-drop multi-upload, per-doc internal flag, per-recipient visibility | 2–3 days |
| **4 — Strip-and-forward** | Outgoing manifest filtering, audit `documents_stripped` event, internal-only badge in UI | 2 days |
| **5 — Entra SSO** | OIDC config, role mapping from Entra groups, internal-user-only enforcement | 1–2 days |
| **6 — Email sender** | DNS work, sender domain config, branded email templates | 0.5 day infra + IT DNS |
| **7 — Hardening** | POPIA review, audit log signing key in Vault/KMS, deployment runbook for IT | 2–3 days |

**Realistic MVP timeline:** ~3 weeks of focused work to ship phase 1–4. Phases 5–7 ship in parallel with internal pilot.

---

## 12. Out of scope for v1

- **AES (Advanced Electronic Signature)** — IG never signs documents requiring it.
- **External user accounts** — counterparties only ever see magic-link signing, never log in.
- **Portfolio-company tenanting** — IG only. Multi-tenancy is phase-3+ and changes the AGPL conversation.
- **Native mobile apps** — web-responsive only. CEO signs on iPad Safari; that's fine.
- **AI features** — clause extraction, risk scoring, etc. Not in MVP. Revisit after platform is stable.

---

## 13. Open questions awaiting Craig

1. **CAF template + approval matrix doc** — needed to validate §6 seed data against IG's actual matrix.
2. **Counterparty witness frequency** — is this used on most contracts or rare?
3. **CEO countersignature** — is it an actual workflow step, or implicit in the pre-counterparty CEO signing?
4. **Existing DocuSign data migration** — do we need to import historical envelopes from DocuSign, or only forward-go new ones?
5. **Retention policy** — how long must IGSIGN retain envelopes? Permanent? 7 years? POPIA conversation.

---

*This spec is the source of truth for IGSIGN scope. Changes go through PRs to `docs/IGSIGN-SPEC.md`. Implementation tasks reference section numbers (e.g., "implements §6 Stage migration").*
