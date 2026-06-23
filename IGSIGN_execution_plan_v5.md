# IGSIGN — Execution Plan v5

**Owner:** Craig G. Lawrence
**Prepared:** 26 May 2026
**Supersedes:** IGSIGN_master_execution_v4.md
**Run target:** Claude Code with FleetView harness, in `C:\Users\Clawre969\Dev\docuseal`

---

## How to use this document

Paste this **entire document** into Claude Code in a single message, prefixed with the instruction line provided to you separately. Claude Code will work through Stages 0 through 8 autonomously, stopping ONLY at the three explicitly-marked **HARD GATES** to await your approval. Soft checkpoints generate a report and continue.

This document supersedes IGSIGN_master_execution_v4.md entirely. Where the two conflict, this document wins. Do not execute any prompts from v4.

---

## Foundation work (Stage 0a + 0b) — RUN BEFORE STAGE 1

These set up the project context and the subagent team. They must complete first because every subsequent stage depends on them.

### Stage 0a — Write project CLAUDE.md

Create `C:\Users\Clawre969\Dev\docuseal\CLAUDE.md` with the content in Appendix A of this document. This file auto-loads at every Claude Code session start and ends the cold-start problem permanently. Target under 200 lines (the appendix is ~140).

### Stage 0b — Write subagent team

Create the directory `.claude/agents/` at the project root. Inside it, create four agent files with the exact content from Appendix B:

1. `igsign-rails-analyst.md` — read-only Rails/DocuSeal expert. Inspects code, traces bugs, reports findings. Does not edit.
2. `igsign-data-modeller.md` — read-only domain expert on the signing state machine and signatory registry. Validates schemas and seed data.
3. `igsign-frontend-reviewer.md` — read-only frontend reviewer. Audits Hotwire/Turbo/Tailwind output against the IG palette and IA.
4. `igsign-qa-verifier.md` — read-only QA. Runs at every gate. Audits acceptance criteria before letting the main session proceed.

**Important constraint:** All four subagents are read-only (no Edit, Write, NotebookEdit, or Bash mutation tools). This is by design — subagents in Claude Code cannot present interactive permission prompts, so any mutating tool call from a subagent is auto-denied. The parent session does all writes. Subagents inspect, analyse, and report.

After creating both the CLAUDE.md and the four agent files, **commit them**:

```
git add CLAUDE.md .claude/agents/
git commit -m "chore: add project context and subagent team for IGSIGN v5 execution"
```

Then proceed to Stage 1.

---

## The eight stages

| Stage | Title | Gate type | Subagent involved |
|---|---|---|---|
| 1 | Replace hallucinated signatory data with real registry | **HARD GATE** | igsign-data-modeller |
| 2 | Rewrite approval matrix & state machine for parallel Stage 0 | **HARD GATE** | igsign-data-modeller |
| 3 | Fix 500s, password reveal, signature drawing | Soft | igsign-rails-analyst |
| 4 | Restructure navigation to 3-tab IA | Soft | igsign-frontend-reviewer |
| 5 | Build visual timeline + pipeline view | Soft | igsign-frontend-reviewer |
| 6 | Wire OpenRouter for contract parsing | Soft | igsign-rails-analyst |
| 7 | Critical bug sweep (from v4 Prompt 1) | Soft | igsign-rails-analyst |
| 8 | End-to-end smoke + go/no-go report | **HARD GATE** | igsign-qa-verifier |

---

## STAGE 1 — Real signatory registry (HARD GATE)

**Goal:** Delete the hallucinated `lib/ig_signatories.rb` content. Replace with a database-backed registry of real people, real entities, and real signing chains.

**Do:**

1. Create a migration `add_signatory_registry.rb` with three tables:

   - `ig_entities` — id, key (e.g. "iti", "comit", "spot_connect"), name, display_name, active, timestamps
   - `ig_signatories` — id, full_name, email (unique), role_title, seniority ("Executive" or "Senior Manager"), active, timestamps
   - `ig_entity_signatories` — join: id, ig_entity_id, ig_signatory_id, position (enum: "bu_head", "bu_cfo", "bu_cfo_alternate", "bu_ceo", "group_signer", "group_signer_alternate", "approver_only"), active, notes

2. Seed `db/seeds/igsign_registry.rb` with the canonical data from Appendix C.

3. Update `lib/ig_signatories.rb` to read from these tables, not hardcoded constants. Keep the public method signatures (`chain_for(entity_key, agreement_type, is_supplier:)`) so nothing else breaks.

4. Add an admin UI route `/legal_ops/signatories` (will be wired into the Legal Ops nav in Stage 4 — for now, raw route is fine) that lists all entries and lets admins toggle `active` or edit `role_title`. Read-only on email and name for now (cannot rename people via UI — too high-risk).

5. Delete any references in code, seeds, or fixtures to: Megan Venter, Valde Ferradaz, John Hawthorne, Greg Goosen, or any name not present in Appendix C. Run `grep -r` for each name in the codebase to verify.

**Subagent step:** Before completing Stage 1, invoke `igsign-data-modeller` with the prompt: "Verify the seeded data in db/seeds/igsign_registry.rb matches the entity → signing chain table in Appendix C of the execution plan. Report any name, email, role, or chain mismatches."

**Acceptance criteria:**
- `bundle exec rails db:migrate db:seed:igsign_registry` completes without errors
- Every entity in Appendix C is present with all its signatories
- No hallucinated names remain anywhere in the codebase
- `IgSignatories.chain_for("iti", "vendor_agreement", is_supplier: true)` returns the correct array of people

**🛑 HARD GATE 1:** After Stage 1 completes, **STOP**. Report:
- Migration ran successfully (yes/no)
- All entities seeded (paste the count and names)
- The output of: `IgSignatories.chain_for("comit", "msa", is_supplier: true).map(&:email)`
- Confirm all hallucinated names removed (paste grep results)

Wait for Craig to type "Approved Stage 1, proceed" before moving to Stage 2.

---

## STAGE 2 — State machine rewrite for parallel Stage 0 (HARD GATE)

**Goal:** Rebuild the signing state machine to match the actual business process — Stage 0 is **parallel** approval by a group, Stage 1 is **single signer** (or a 2-step sub-sequence for Spot Connect), Stage 2 is counterparty.

**Background:** The current state machine sends invites sequentially in Stage 0 (one person at a time, waiting for each before inviting the next). This is wrong. The Group Signature Process PDF mandates parallel approval — all Stage 0 approvers receive the invite simultaneously.

**Do:**

1. Modify `CafStage` model: add `routing` enum field with values `:sequential` and `:parallel`. Default sequential for backwards compatibility.

2. Modify `CafSubmissionCreator`:
   - When building Stage 0, set `routing: :parallel`
   - When building Stage 0 submitters, fire ALL invites simultaneously (not waiting for sign-back)
   - When building Stage 1, check the entity — if `spot_connect`, build two sub-stages (Siddeek then Sean). Otherwise, single signer.
   - For NDAs: Stage 0 = Craig Lawrence only. No Stage 1. Direct to counterparty.

3. Modify `CafWebhookHandler` and `CafCompletionHandler`:
   - On parallel stage, completion fires when ALL submitters in the stage have signed (not when one signs)
   - On any decline in parallel stage, halt workflow and notify Legal + requestor
   - Maintain the existing sequential behaviour for Stage 1 (and Spot Connect's two-step Stage 1)

4. Add a new agreement field `commercial_relationship` (enum: `:customer`, `:supplier`). Migration: `add_column :caf_workflows, :commercial_relationship, :integer, default: 0`.

5. In `CafSubmissionCreator`, when `is_supplier?` is true, add Callie Baney (Procurement) to Stage 0 approvers.

6. Update `CafApprovalMatrix.resolve_for` to factor in the commercial_relationship — different chains for supplier vs customer of the same entity+type.

7. **IFS special case:** For IFS / Viva Cover / Viva Life entities, Sean Bergsma appears in Stage 0 as an approver (not Stage 1 signer). Kobus Botha signs Stage 1 alone. Verify this is handled correctly.

**Subagent step:** After implementing, invoke `igsign-data-modeller` with: "Trace through the state machine for these five scenarios and confirm each behaves correctly: (1) ITI customer MSA, (2) Comit supplier vendor agreement, (3) Spot Connect customer service agreement, (4) IFS supplier agreement, (5) NDA from ITI. Report the exact sequence of invites for each."

**Acceptance criteria:**
- All five scenarios above produce the correct invite sequence
- Parallel Stage 0 sends all invites within the same Sidekiq batch
- Spot Connect Stage 1 sends to Siddeek first, then Sean only after Siddeek signs
- IFS Stage 0 includes Sean as approver; IFS Stage 1 is Kobus alone
- Specs for `CafSubmissionCreator` and `CafCompletionHandler` updated to cover parallel flow

**🛑 HARD GATE 2:** After Stage 2 completes, **STOP**. Report:
- The five scenario traces from the data-modeller subagent
- Migration ran successfully (yes/no)
- Spec results (`bundle exec rspec spec/services/caf_submission_creator_spec.rb`)

Wait for Craig to type "Approved Stage 2, proceed" before moving to Stage 3.

---

## STAGE 3 — Fix 500s, password reveal, signature drawing (Soft checkpoint)

**Goal:** Make every page a logged-in user can navigate to return 200. Fix the specific UX bugs Craig reported.

**Do:**

1. **Diagnose the 500s.** Run the app locally (or on staging) and visit:
   - `/settings/profile` — known 500
   - `/templates` (admin view) — known 500
   - `/agreements/new`
   - `/agreements`
   - `/companies`
   - `/legal_ops/workflows` (currently `/admin/workflows`)
   - `/legal_ops/approval_matrices`

   For each 500, invoke `igsign-rails-analyst` with: "Read the production log lines around this exception. Identify root cause. Report the file, line, and a one-sentence fix recommendation." Then implement the fix in the parent session.

2. **Password reveal toggle.** On every password input in the app:
   - Add a Lucide eye/eye-off icon button inside the field
   - Toggle `type="password"` ↔ `type="text"` on click
   - Use a Stimulus controller (`password_reveal_controller.js`) so it works consistently
   - Verify on: login, password change, password reset, account creation

3. **Signature and initials drawing.** This is DocuSeal native functionality. Diagnose why it's broken:
   - Open browser dev tools on the signing page
   - Check console errors when clicking "Sign" or "Initial"
   - Most likely cause: a JS asset is failing to compile (importmap or esbuild issue) or a canvas library import is broken
   - Fix the import chain so the signature canvas renders

4. **Verify all fixed pages return 200.** Run a check task:
   ```
   bin/rails runner "
     paths = ['/settings/profile', '/templates', '/agreements/new', '/agreements', '/companies', '/legal_ops/workflows']
     paths.each do |p|
       response = Net::HTTP.get_response(URI(\"http://localhost:3000#{p}\"))
       puts \"#{p}: #{response.code}\"
     end
   "
   ```

**Subagent step:** Invoke `igsign-rails-analyst` once at the end of Stage 3 with: "Audit the changes made in Stage 3. Are there any other controllers or views that share the same broken pattern as the 500s I fixed, that I might have missed?"

**Soft checkpoint:** Report all 500s found and fixed. List the paths now returning 200. Continue to Stage 4 unless any critical fix is incomplete.

---

## STAGE 4 — IA restructure to 3-tab navigation (Soft checkpoint)

**Goal:** Collapse the current 5-tab IA into 3 logical groups. Move admin functions under a "Legal Ops" parent.

**Target navigation:**

```
[IGSIGN logo]   Agreements  |  Counterparties  |  Legal Ops  ▾    [+ New Agreement]   [Settings]   [Avatar]
                                                  ├── Approval Matrices
                                                  ├── Templates
                                                  ├── Signatory Registry
                                                  └── Workflow Log
```

**Do:**

1. Rename routes:
   - `/admin/workflows` → `/legal_ops/workflows`
   - `/admin/approval_matrices` → `/legal_ops/approval_matrices`
   - `/admin/templates` → `/legal_ops/templates`
   - Add `/legal_ops/signatories` (the registry from Stage 1)
   - Add `/legal_ops` index page with cards linking to each sub-section
   - Add 301 redirects from old paths so any saved links don't break

2. Rename "Contacts" → "Counterparties" everywhere it appears (route, nav label, page title, breadcrumbs).

3. **Delete the "Operations" tab.** Its functionality (the CAF list) was a duplicate of the Agreements tab. The CAF concept moves to a status filter on Agreements ("View CAF-only" toggle), not its own tab.

4. **Delete the standalone "Templates" top-level tab.** Templates only exist under Legal Ops now. The current /templates DocuSeal route can remain for the raw editor (admins go there to create the actual template fields), but it's not in the user-facing nav.

5. Update the navbar partial (`app/views/shared/_navbar.html.erb`) to render the 3-tab structure with a dropdown for Legal Ops.

6. Mobile: dropdown collapses to a hamburger with the same 3 sections expanded.

**Subagent step:** Invoke `igsign-frontend-reviewer` with: "Review the new navbar. Does it match IG's design language (Arctic Black + IG Green, DM Sans)? Are the active states clear? Does it work on mobile (320px wide)?"

**Soft checkpoint:** Report the new nav structure, before/after screenshots if possible, and the frontend-reviewer's feedback. Continue to Stage 5.

---

## STAGE 5 — Visual timeline + pipeline view (Soft checkpoint)

**Goal:** Build the two visualisations Craig has called for repeatedly.

**Part A — Agreement detail timeline:**

On `/agreements/:id` (show page), replace the existing signing_journey partial with a horizontal timeline showing:

```
[Draft]  →  [Internal Approval (parallel)]  →  [Group Signer]  →  [Counterparty]  →  [Complete]
   ✓               ⏳ 3 of 5 signed                pending             pending           pending
```

Each stage:
- **Completed**: green checkmark, completion timestamp
- **Current**: navy with subtle pulse, "Waiting X days" if > 1 day
- **Upcoming**: muted grey

For the parallel Stage 0, show a sub-grid of the 5 approvers with their individual status (signed / pending / declined).

Below the timeline, an **Entity + Relationship card**:
- Entity badge (e.g. "ITI" in navy)
- Customer / Supplier chip (blue for customer, amber for supplier)
- Counterparty company name
- Days in current stage (red if > 5)

**Part B — Pipeline view on index:**

Add a toggle on `/agreements` between table view and kanban-style pipeline view.

Pipeline columns: **Draft | Awaiting Approval | Group Signer | With Counterparty | Complete**

Each card shows:
- Agreement title
- Entity chip
- Customer/Supplier chip
- Current holder's name
- Days in stage
- Quick-action button (Remind / View)

Save the user's view preference (table vs pipeline) in localStorage.

**Part C — Customer/Supplier filter:**

Add filter chips above the list (both views): All | Customer | Supplier | NDA. Backed by URL params so filters persist on reload.

**Subagent step:** Invoke `igsign-frontend-reviewer` with: "Audit the timeline and pipeline view for IG palette adherence, accessibility (contrast, keyboard nav), and mobile responsiveness. Report any issues."

**Soft checkpoint:** Report the new visualisations and continue to Stage 6.

---

## STAGE 6 — OpenRouter contract parsing (Soft checkpoint)

**Goal:** Replace the planned Anthropic-direct integration with OpenRouter, using a free-tier model for POC.

**Do:**

1. Add gem `openrouter` (or use plain `Faraday` against the OpenAI-compatible endpoint — your call, but Faraday is lighter).

2. Environment variables (add to Render dashboard, and document in CLAUDE.md):
   ```
   AI_API_KEY=sk-or-v1-...     (OpenRouter key)
   AI_BASE_URL=https://openrouter.ai/api/v1
   AI_MODEL=meta-llama/llama-3.3-70b-instruct:free
   ```
   Variable naming is provider-agnostic so we can swap later.

3. Create `app/services/contract_parser.rb`:
   ```ruby
   class ContractParser
     def self.extract(contract_text)
       client = Faraday.new(url: ENV['AI_BASE_URL']) do |f|
         f.request :json
         f.response :json
         f.headers['Authorization'] = "Bearer #{ENV['AI_API_KEY']}"
       end
       response = client.post('chat/completions', {
         model: ENV['AI_MODEL'],
         messages: [
           { role: 'system', content: SYSTEM_PROMPT },
           { role: 'user', content: contract_text }
         ],
         response_format: { type: 'json_object' }
       })
       JSON.parse(response.body.dig('choices', 0, 'message', 'content'))
     rescue => e
       Rails.logger.error("[IGSIGN] ContractParser failed: #{e.message}")
       { 'error' => e.message }
     end
   end
   ```

4. The system prompt extracts: purpose (1 sentence), value_zar, term_months, payment_terms, governing_law, high_risk_clauses (array of {type, summary, severity}). Save the prompt to `config/prompts/extract_contract_v1.md`.

5. Wire into the upload flow. After `Templates::CreateAttachments.call` succeeds, enqueue a `ContractParsingJob` (Sidekiq). The job extracts text from the PDF, calls `ContractParser.extract`, and saves to `caf_workflow.parsed_contract_data` (jsonb column — add migration).

6. On the review page, show a "Smart Summary" card with the extracted data. High-risk clauses get severity-coloured chips.

7. **Privacy note in CLAUDE.md:** Document that contract text is sent to OpenRouter (which routes to Meta's hosted Llama). For POC this is acceptable; for production with real client contracts, switch to a self-hosted or zero-data-retention provider.

**Subagent step:** Invoke `igsign-rails-analyst` with: "Audit the ContractParsingJob for failure modes. What happens if (a) AI_API_KEY is unset, (b) OpenRouter is down, (c) the response isn't valid JSON, (d) the contract is too long for the model's context window? Report fixes."

**Soft checkpoint:** Report the integration status and continue to Stage 7.

---

## STAGE 7 — Critical bug sweep (Soft checkpoint)

**Goal:** Clear the 7 critical/high bugs from v4 Prompt 1 that aren't already covered by Stages 1-6.

The 7 bugs:
1. Draft "Continue" link routes non-NDA drafts to review, skipping upload → 500
2. Blank counterparty email advances workflow silently, no email sent
3. NDA audit bundle emails have no attachment
4. INTERNAL_WEBHOOK_SECRET not validated — accepts all webhook calls if env var unset
5. Empty CafApprovalMatrix stages_config silently hangs workflow
6. caf_preview crashes on draft with nil entity
7. auto_place_fields! silent failure produces no user feedback

For each: implement the fix per v4 Prompt 1 spec, add a regression test, commit. Detailed fix specs are in v4 Prompt 1 (which remains valid as a reference for these specific bugs even though we discarded v4's overall sequencing).

**Subagent step:** After all 7 are fixed, invoke `igsign-rails-analyst` with: "Run the regression test suite. Report any failures. Then audit for any OTHER places in the codebase where the same anti-pattern (silent failure, missing nil guard, unvalidated env var) appears."

**Soft checkpoint:** Report the 7 fixes, test results, and any additional issues found. Continue to Stage 8.

---

## STAGE 8 — End-to-end smoke + go/no-go (HARD GATE)

**Goal:** Run one real workflow end-to-end. Confirm the system is pilot-ready.

**Do:**

1. Create the IGSIGN CAF Template manually in DocuSeal's template editor (this is a manual step — Craig will do this, OR Claude Code will prompt and wait if not present).

2. Run `rake igsign:smoke_test` (build this task in Stage 8 if it doesn't exist). It checks:
   - All seeded entities present
   - All seeded signatories present
   - IGSIGN CAF Template exists with required fields
   - SMTP env vars set
   - INTERNAL_WEBHOOK_SECRET set
   - AI_API_KEY set
   - Redis connected
   - Sidekiq running

3. Run a synthetic end-to-end:
   - Log in as Craig
   - Create an NDA agreement, entity ITI, counterparty = Craig's personal email
   - Send
   - Receive the email (check Resend dashboard)
   - Sign as Craig (Stage 0 = Craig Lawrence alone, per NDA rule)
   - Receive the counterparty invite at the personal email
   - Sign as counterparty
   - Confirm audit bundle arrives at all recipients

4. If any step fails: report and pause. Do not mark Stage 8 complete.

**Subagent step:** Invoke `igsign-qa-verifier` with the full execution plan as context and the prompt: "Audit Stages 1-7 against their acceptance criteria. Produce a go/no-go recommendation for pilot launch with Sean, Donovan, Laren. Include any items you would block pilot on, items you would caveat pilot with, and items that are non-blocking but should be tracked."

**🛑 HARD GATE 3:** Report:
- Smoke test results (full output)
- End-to-end test result (pass/fail with timestamps)
- QA-verifier's go/no-go recommendation
- Final commit hash

Wait for Craig to make the pilot decision.

---

## Defaults that need no approval throughout

- Fix bugs found incidentally during any stage's work
- Add tests for any new code (RSpec, request specs for controllers, model specs for models, service specs for services)
- Run `rubocop --autocorrect-all` before each commit
- Run `bundle exec rspec` before each push; fix failures before pushing
- Use existing patterns from the codebase
- Commit after each logical unit of work, push at the end of each stage
- If a subagent reports an issue, fix it before the gate

---

## Things that DO require approval (besides the 3 hard gates)

- Any schema change that would drop or rename existing columns with data in them
- Any change to email content sent to external counterparties
- Any change to the IgSignatories registry beyond what Appendix C specifies
- Anything that modifies how counterparties sign (their flow is the most fragile UX)

For these, pause and ask in chat.

---

## What v4 said to do that we are explicitly NOT doing

- **No staff walkthrough / intro.js tour** (v4 Phase 5 Part B). It's premature — fix the foundation first, add onboarding when there's something stable worth onboarding people to.
- **No CI fix in scope** (v4 Phase 6). CI failures will be addressed by the test suite work in each stage. Dedicated CI sprint comes after pilot.
- **No Phase 5 Entra SSO**. Local auth is sufficient for pilot. SSO is a 1-week sprint of its own, post-pilot.
- **No counterparty help panel / progress indicator in Stage 5** (v4 Phase 5 Part A items 2 & 3). Welcome modal stays; the rest waits.
- **No `parsed_contract_data` UI Smart Summary in Stage 6** if the parsing is unreliable on the free Llama model — implement extraction and storage, gate the UI behind a feature flag.

---

# APPENDIX A — CLAUDE.md content

Save the content between the `=== BEGIN ===` and `=== END ===` markers as `CLAUDE.md` at the project root. Do not include the markers themselves in the file.

```
=== BEGIN CLAUDE.md ===
# IGSIGN — Project Context

Internal e-signature platform for Ignition Group built on a DocuSeal fork.
Rails 8.1.3, PostgreSQL, Redis (Upstash), Sidekiq, ActionMailer (Resend SMTP).
Deployed to Render. Working tree on Windows at C:\Users\Clawre969\Dev\docuseal.

## What IGSIGN does

Routes commercial agreements through a 3-stage signing flow:
- Stage 0: parallel internal approval by BU Head, BU CFO, Group CLO, Group CFO, +Procurement if supplier
- Stage 1: single signer (Sean Bergsma CEO, Don Bergsma COO, or entity-specific exception)
- Stage 2: counterparty signs

NDAs bypass Stages 0 (Craig Lawrence approves alone) and 1 (no group signer).

## Architectural decisions

- Subagents in .claude/agents/ are read-only. Parent does all writes.
- Signatory data is database-backed (ig_entities, ig_signatories, ig_entity_signatories), NOT hardcoded in lib/ig_signatories.rb.
- Stage 0 routing is parallel. Do not revert to sequential.
- Customer vs supplier is captured per agreement via CafWorkflow#commercial_relationship.
- AI parsing uses OpenRouter (env vars AI_API_KEY, AI_BASE_URL, AI_MODEL) — provider-agnostic naming.
- The "Operations" tab is deleted; CAF management lives under Legal Ops.
- Three top-level nav tabs: Agreements, Counterparties, Legal Ops.

## Conventions

- Tests live in spec/, RSpec, not Minitest.
- Run rubocop --autocorrect-all before every commit.
- Run bundle exec rspec before pushing.
- Migrations use timestamps, not version numbers.
- Use Hotwire/Turbo for interactivity; Stimulus controllers for JS. No new React or Vue.
- Tailwind for styling. IG palette: Arctic Black #0B1722, IG Green #00C853, supporting greys.
- Font: DM Sans.

## Real signing authority

The canonical signatory registry is seeded from db/seeds/igsign_registry.rb. The names in lib/ig_signatories.rb prior to 26 May 2026 included hallucinated people (Megan Venter, etc.) and entities that no longer exist (former staff). The seed file is the source of truth.

Group signers are limited to: Sean Bergsma (CEO), Don Bergsma (COO), Kobus Botha (IFS only), Siddeek Rahim (Spot Connect only, signs before Sean). NDAs are signed by Craig Lawrence alone.

## Gotchas

- DocuSeal's /templates path still works for the raw template editor. /legal_ops/templates is the IGSIGN-managed metadata layer over it.
- LibreOffice runs in the Docker image for DOCX → PDF. If conversion fails, the profile lock is the usual culprit (see CafSubmissionCreator).
- Sidekiq is embedded in Puma (single process). WEB_CONCURRENCY=0 in Render.
- AIM90 leaderboard telemetry posts every tool use to aim90-leaderboard.vercel.app. Be aware that sensitive contract text passing through ContractParser may appear in tool logs.
- Subagents cannot present permission prompts. Any tool needing approval must be invoked by the parent session, never delegated.

## Where things live

- Models: app/models/caf_*.rb, app/models/igsign_*.rb
- Services: app/services/caf_*.rb, app/services/contract_parser.rb
- Webhook ingress: app/controllers/internal/caf_webhooks_controller.rb (require INTERNAL_WEBHOOK_SECRET)
- Mailers: app/mailers/caf_*_mailer.rb, app/mailers/reminder_mailer.rb
- Signing registry: db/seeds/igsign_registry.rb (source of truth)
- Approval rules: app/models/caf_approval_matrix.rb + admin UI at /legal_ops/approval_matrices

## Commands

- bin/rails s — local server
- bin/rails db:migrate — migrations
- bundle exec rspec — tests
- rubocop --autocorrect-all — lint
- rake igsign:smoke_test — pre-deploy smoke check

## Pilot users

Craig Lawrence (CLO), Sean Bergsma (CEO), Donovan Bergsma (COO), Laren Farquharson (CFO).
Default password IgSign2026! — must be changed on first login.
=== END CLAUDE.md ===
```

---

# APPENDIX B — Subagent files

Create each as a separate file in `.claude/agents/`.

## File: `.claude/agents/igsign-rails-analyst.md`

```
---
name: igsign-rails-analyst
description: Use this agent when investigating Rails errors, tracing bugs through the IGSIGN codebase (DocuSeal fork on Rails 8.1.3), diagnosing 500 errors, auditing controller/model/service code, or analysing the CAF workflow services. Use proactively when a stage of the execution plan involves code investigation before writes. Read-only — reports findings to the parent session, which performs any edits.
tools: Read, Grep, Glob, Bash
model: sonnet
---

You are a senior Rails engineer specialising in the IGSIGN codebase — a DocuSeal fork on Rails 8.1.3 running on Render. You are read-only by design: you investigate, trace, and report. You do not edit. The parent session handles all writes.

When invoked you receive a specific question or symptom. Your output is always a structured report:

1. **What I found** — the specific files, lines, and code paths relevant to the question.
2. **Root cause** — your best hypothesis, with confidence level (high/medium/low).
3. **Recommended fix** — concrete, file-and-line specific. One paragraph max.
4. **Risks / side effects** — anything the parent should watch when implementing.

You know the IGSIGN architecture:
- CafWorkflow is the central record. CafStage models each signing stage. CafStageSubmitter is one row per person signing in a stage.
- CafSubmissionCreator builds DocuSeal submissions and wires the staging.
- CafWebhookHandler processes DocuSeal callback events.
- CafCompletionHandler runs when Stage 0 finishes, strips CAF from documents, activates Stage 1.
- CafAuditBundleSender distributes the audit pack on completion.
- IgSignatories module (lib/ig_signatories.rb) is the public API into the signatory registry. Post-26-May-2026 it reads from the database, not constants.

Common gotchas you watch for:
- nil guards missing on caf.entity, caf.contract_document, caf.counterparty_email
- INTERNAL_WEBHOOK_SECRET unset (auth bypass)
- LibreOffice DOCX→PDF failures (profile lock)
- Sidekiq jobs failing silently if Redis credentials are stale
- DocuSeal template UUIDs not remapping correctly on duplicate

Be concise. Do not speculate beyond what you can verify by reading the code. If you cannot answer with confidence, say so.
```

## File: `.claude/agents/igsign-data-modeller.md`

```
---
name: igsign-data-modeller
description: Use this agent when validating signatory registry data, tracing approval chains, verifying the state machine logic, or confirming seed data matches the canonical mapping. Use proactively at Stages 1 and 2 of the execution plan, and any time changes are made to ig_entities, ig_signatories, ig_entity_signatories, CafApprovalMatrix, or the CafStage/CafSubmissionCreator state machine. Read-only — reports findings to the parent session.
tools: Read, Grep, Glob, Bash
model: sonnet
---

You are a domain modelling expert for the IGSIGN signing state machine. You own the correctness of:
- The signatory registry (ig_entities, ig_signatories, ig_entity_signatories)
- The approval matrix (CafApprovalMatrix) and its resolution logic
- The CAF state machine (CafStage routing: sequential vs parallel)
- The CafSubmissionCreator's chain-building logic

You are read-only. You inspect data, trace logic, and report. The parent session edits.

When invoked, your output is always a structured report:

1. **The trace** — the exact sequence of database records, method calls, or invitations the system would produce for the given scenario.
2. **Anomalies** — any deviation from the canonical mapping (Appendix C of IGSIGN_execution_plan_v5.md). List each by entity, position, expected vs actual.
3. **Confidence** — high/medium/low, with reasoning.

Canonical signing rules you must enforce:

- Stage 0 is always parallel. All approvers invited simultaneously.
- Stage 0 = Requestor + BU Head + BU CFO + Group CLO (Craig L) + Group CFO (Laren) + [Callie Baney IF supplier]
- Stage 1 = single signer per entity per matrix rule. Sean Bergsma OR Don Bergsma. Two exceptions:
  - Spot Connect: Siddeek Rahim signs first, then Sean (two sub-stages).
  - IFS / Viva Cover / Viva Life: Kobus Botha signs alone; Sean is an Approver in Stage 0, not a signer.
- NDAs: Stage 0 = Craig Lawrence alone. No Stage 1. Direct to counterparty.
- Customer agreements: no Procurement (Callie).
- Supplier agreements: Procurement (Callie) added to Stage 0.

You know who is real and who was hallucinated. These names are real (full registry in Appendix C of the execution plan): Sean Bergsma, Donovan Bergsma, Craig G Lawrence, Laren Farquharson, Callie Baney, William Talbot, Mark Mitchell, Daniel Swart, Matthew Van As, Ivor vonNielen, Nikola Ramsden, Siddeek Rahim, Verona Naidoo, Daniel Schauffer, Kobus Botha, Angeline Bennett, Pedro Casimiro, Allan Randell, Richard Swart, Craig DaRocha.

These names should NOT appear anywhere: Megan Venter, Valde Ferradaz, John Hawthorne, Greg Goosen, or any name not in the list above.

Entities are: ITI, Comit, MVNX, Spot Connect (formerly UConnect), Ignition Digital LLC, Ignition CX (US), IFS (with Viva Cover, Viva Life), Gumtree, Spot Money. Nine entities. Not thirteen.

Be precise. Report exact emails, not approximate names. If something is ambiguous, flag it as a question for Craig rather than guessing.
```

## File: `.claude/agents/igsign-frontend-reviewer.md`

```
---
name: igsign-frontend-reviewer
description: Use this agent when reviewing frontend changes — Hotwire/Turbo templates, Stimulus controllers, Tailwind styling, navigation, or visual components. Use proactively after Stages 4 and 5 of the execution plan, or any time a view is changed. Audits against IG brand palette and accessibility standards. Read-only.
tools: Read, Grep, Glob
model: sonnet
---

You are the frontend design reviewer for IGSIGN. You audit views, partials, Stimulus controllers, and stylesheets against the IG visual standard.

You are read-only. You review and report. The parent session edits.

Your output format:

1. **Brand adherence** — does this use IG Green (#00C853), Arctic Black (#0B1722), DM Sans? Or does it leak DocuSeal's default styling?
2. **Accessibility** — colour contrast (WCAG AA min), keyboard navigation, ARIA labels on interactive elements, focus states visible.
3. **Mobile** — does it work at 320px, 768px, 1024px? Any horizontal scroll, any cut-off content?
4. **Consistency** — does this match how other IGSIGN pages render the same pattern (e.g. cards, badges, buttons)?
5. **Specific issues** — file, line, fix recommendation.

IG visual standard:
- Primary: Arctic Black #0B1722 (navbar background, headings)
- Accent: IG Green #00C853 (primary buttons, active states, success)
- Greys: Tailwind slate-50, slate-100, slate-300, slate-600, slate-900
- Status colours: Tailwind emerald-500 (success), amber-500 (warning), rose-500 (error)
- Font: DM Sans for everything. Avoid system-ui defaults from DocuSeal.
- Buttons: rounded-lg, font-medium, px-4 py-2 minimum, focus:ring-2.
- Cards: bg-white, rounded-xl, shadow-sm, border border-slate-200.
- Badges: rounded-md, text-xs, font-medium, px-2 py-0.5.

Anti-patterns you flag:
- Inline styles instead of Tailwind classes
- Generic "primary" / "secondary" button labels with no variant
- DocuSeal blue (#1f47ff or similar) leaking through
- Text smaller than text-sm without justification
- Buttons under 44px tall on mobile (touch target minimum)
- Missing focus states (Tailwind focus-visible: ring)

Be specific. "The button on line 42 of agreements/show.html.erb is missing focus:ring-2 — keyboard users get no focus indicator" beats "accessibility could be improved."
```

## File: `.claude/agents/igsign-qa-verifier.md`

```
---
name: igsign-qa-verifier
description: Use this agent at every hard gate of the IGSIGN execution plan and at any point when the parent claims a stage is complete. Audits work against the stage's acceptance criteria before allowing progression. Read-only. The verifier of last resort.
tools: Read, Grep, Glob, Bash
model: opus
---

You are the QA verifier for the IGSIGN build. You exist to catch "looks done" failures.

You are invoked at every hard gate of the execution plan (Stages 1, 2, 8) and any time the parent session believes a stage is complete. Your job is to audit, not to be agreeable. If something is incomplete or wrong, say so plainly.

Your output is always:

1. **Acceptance criteria audit** — for each criterion of the stage, mark PASS / PARTIAL / FAIL with one-line evidence.
2. **Things the parent claimed but did not verify** — specifics.
3. **Risks if we proceed** — what breaks downstream if we move on with current state.
4. **Recommendation** — PROCEED / PROCEED WITH CAVEATS / BLOCK.

You read the execution plan, the relevant code, the test results, and the relevant data. You do not take the parent's word for completion — you verify.

Things you specifically watch for:
- Tests that exist but do not actually exercise the changed code
- Migrations that ran but seeded incomplete or wrong data
- Refactors that left old code paths intact alongside new ones (dead code)
- Hardcoded values that should be env vars
- Silent rescues that swallow errors
- Subagent reports the parent did not actually act on
- Stage gates the parent tried to skip

You are not adversarial for its own sake. If work is genuinely done, say so. If the parent did good work on a hard problem, acknowledge it. But you do not soften "FAIL" into "almost complete" or wave through partial work.

When in doubt, BLOCK and explain. The cost of stopping for a real check is low. The cost of pilot-launching a broken system is high.
```

---

# APPENDIX C — Canonical entity + signatory data

This is the source of truth for `db/seeds/igsign_registry.rb`. The seed file should generate one `IgEntity`, one or more `IgSignatory`, and the `IgEntitySignatory` joins to reflect this table.

## Signatories

| full_name | email | role_title | seniority |
|---|---|---|---|
| Sean Bergsma | Sean.Bergsma@ignitiongroup.co.za | Group CEO | Executive |
| Donovan Bergsma | Donovan.Bergsma@ignitiongroup.co.za | Group COO | Executive |
| Craig G. Lawrence | Clawre969@ignitiongroup.co.za | Group CLO | Executive |
| Laren Farquharson | Laren.Farquharson@ignitiongroup.co.za | Group CFO | Senior Manager |
| Callie Baney | Callie.Baney@ignitiongroup.co.za | Group Head of Projects & Procurement | Senior Manager |
| William Talbot | William.Talbot@ignitiongroup.co.za | Business Lead — ITI (NRP and Platforms) | Senior Manager |
| Mark Mitchell | Mark.Mitchell@ignitioncx.com | Chief Client Officer | Senior Manager |
| Daniel Swart | Daniel.Swart@mvnxmobile.co.za | Executive Head, MVNX | Senior Manager |
| Matthew Van As | Matthew.VanAs@mvnxmobile.co.za | Finance Director, MVNX | Senior Manager |
| Ivor vonNielen | ivor.vonnielen@uconnect.co.za | COO, Spot Connect | Senior Manager |
| Nikola Ramsden | Nikola.Ramsden@spot.co.za | Interim Finance Director (Spot Connect + Spot Money) | Senior Manager |
| Siddeek Rahim | siddeek.rahim@uconnect.co.za | CEO, Spot Connect | Executive |
| Verona Naidoo | Verona.Naidoo@ignitiongroup.co.za | CFO Ignition CX | Executive |
| Daniel Schauffer | Daniel.Schauffer@ignitiongroup.co.za | Senior Finance Manager, Comit (alternate) | Senior Manager |
| Kobus Botha | kobus.botha@igfs.co.za | CEO, IFS | Executive |
| Angeline Bennett | angeline.bennett@igfs.co.za | Finance Director, IFS | Senior Manager |
| Pedro Casimiro | Pedro.Casimiro@ignitiongroup.co.za | Business Lead — Gumtree | Senior Manager |
| Allan Randell | Allan.Randell@spot.co.za | Head of Product, Spot Money | Senior Manager |
| Richard Swart | Richard.Swart@ignitiongroup.co.za | Executive Head: Telco (pAIments) | Executive |
| Craig DaRocha | Craig.DaRocha@ignitiongroup.co.za | Head of Client Management (OnAir) | Executive |

## Entities and chains

For each entity, Stage 0 always includes: Requestor (dynamic) + BU Head + BU CFO + Craig Lawrence + Laren Farquharson + Callie Baney (if supplier only).

| Entity (key) | Display Name | BU Head | BU CFO | BU CFO Alt | Group Signer | Group Signer Alt | Special |
|---|---|---|---|---|---|---|---|
| iti | Ignition Telecoms Investments | William Talbot | Laren Farquharson¹ | — | Sean Bergsma | Don Bergsma (operational/intra-co) | — |
| comit | Comit Technologies | Mark Mitchell | Verona Naidoo | Daniel Schauffer | Sean Bergsma | — | — |
| mvnx | MVNX | Daniel Swart | Matthew Van As | — | Sean Bergsma | — | — |
| spot_connect | Spot Connect | Ivor vonNielen | Nikola Ramsden | — | Siddeek Rahim → Sean Bergsma | — | Stage 1 has 2 sub-stages |
| ignition_digital | Ignition Digital LLC | Mark Mitchell | Verona Naidoo | — | Don Bergsma | — | — |
| ignition_cx_us | Ignition CX (US) | Mark Mitchell | Verona Naidoo | — | Don Bergsma | — | — |
| ifs | IFS (incl Viva Cover, Viva Life) | Kobus Botha² | Angeline Bennett | — | Kobus Botha | — | Sean Bergsma is Stage 0 approver only |
| gumtree | Gumtree | Pedro Casimiro | — | — | Don Bergsma | — | BU CFO TBC at agreement creation |
| spot_money | Spot Money | Allan Randell | Nikola Ramsden | — | Sean Bergsma | — | — |

¹ Laren is Group CFO employed at ITI. She therefore appears as both ITI's BU CFO and as Group Finance for every entity's Stage 0. The seed should add her to ITI as `bu_cfo` and to every entity as `group_finance`.

² For IFS, Kobus is treated as both the BU Head (since IFS is autonomous) and the Stage 1 signer. He doesn't sign Stage 0 again. Sean is added as Stage 0 approver-only (position: `approver_only`).

## Approval matrix rules to seed

Five default matrices:

1. **Default NDA** — applies to NDA type, any entity, no value threshold. Stages: just Stage 0 (Craig alone) → Counterparty.

2. **Default Short Form CAF** — applies to: ADDENDUM, SLA, POLICY, OTHER. Any entity. No value threshold. Stages: Stage 0 (parallel) → Stage 1 (group signer per entity) → Counterparty.

3. **Default Long Form CAF — under R5m** — applies to: MSA, VENDOR, EMPLOYMENT. Any entity. Value < R5,000,000. Same stages as Short Form CAF.

4. **Default Long Form CAF — R5m and above** — applies to: MSA, VENDOR, EMPLOYMENT. Any entity. Value ≥ R5,000,000. Same stages but flagged for senior review by CLO before send.

5. **IFS exception** — applies to: any type. Entity = IFS or Viva Cover or Viva Life. Stage 0 includes Sean Bergsma as approver. Stage 1 = Kobus Botha alone.

---

# End of execution plan

Run order: Stage 0a (CLAUDE.md) → Stage 0b (subagents) → Stages 1-8 with gates.
Estimated calendar time: 6-8 focused working days, depending on how many bugs surface in Stage 3.

The single instruction to paste alongside this plan into Claude Code is provided to you separately.
