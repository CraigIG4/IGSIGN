# IGSIGN — Project Context

Internal e-signature platform for Ignition Group built on a DocuSeal fork.
Rails 8.1.3, PostgreSQL, Redis (embedded), Sidekiq (embedded in Puma), ActionMailer (Postmark/SES pending).
Deployed on-prem POC server at 172.30.0.30 via Docker Compose. Working tree on Windows at C:\Users\Clawre969\Dev\docuseal.

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

## AI contract parsing (Stage 6)

Env vars (set in Render dashboard — do NOT commit to source):
- `AI_API_KEY` — OpenRouter API key (sk-or-v1-...)
- `AI_BASE_URL` — https://openrouter.ai/api/v1
- `AI_MODEL` — meta-llama/llama-3.3-70b-instruct:free (or any OpenAI-compatible model name)

Flow: after document upload → `ContractParsingJob` (Sidekiq) → `DocumentMetadatas.build_text_runs` extracts PDF text via Pdfium → `ContractParser.extract` posts to OpenRouter → result saved to `caf_workflows.parsed_contract_data` (jsonb).

System prompt: `config/prompts/extract_contract_v1.md`

**Privacy:** Contract text is sent to OpenRouter (Meta Llama hosted model). Acceptable for POC. For production with live client contracts, switch to a self-hosted model or a provider with a zero-data-retention agreement.

Smart Summary card on the review page renders only when `parsed_contract_data` is present and contains no `error` key (feature-flagged by data presence). If AI_API_KEY is unset, the job silently skips and the card does not appear.

## Pilot users

Craig Lawrence (CLO), Sean Bergsma (CEO), Donovan Bergsma (COO), Laren Farquharson (CFO).
Default password IgSign2026! — must be changed on first login.
