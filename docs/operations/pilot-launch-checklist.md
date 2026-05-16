# IGSIGN Pilot Launch Checklist

**Environment:** Production  
**Prepared by:** Ops & Pilot Lead  
**Last updated:** 2026-05-16

---

## Pre-launch

- [ ] Docker image built and pushed (`docker build` passes, `docker push` succeeds)
- [ ] Container deployed to production host
- [ ] Environment variables set: `DATABASE_URL`, `SECRET_KEY_BASE`, `RAILS_ENV=production`
- [ ] `bundle exec rails db:migrate` run successfully against production database
- [ ] `bundle exec rails db:seed` run successfully — confirm output includes all expected lines:
  - `Account already exists: Ignition Group` (or `Created account:`)
  - `Admin user already exists: craig@ignitiongroup.co.za` (or `Created admin user:`)
  - `Created pilot admin: sean@ignitiongroup.co.za` (or `already exists`)
  - `Created pilot admin: donovan@ignitiongroup.co.za` (or `already exists`)
  - `Created pilot admin: laren@ignitiongroup.co.za` (or `already exists`)
  - `IGSIGN CAF Template: already exists` (or seeded + fields count)
  - Four approval matrix lines

---

## Pilot user handover

The following users are seeded with the default password **`IgSign2026!`**.

| Name | Email | Role |
|---|---|---|
| Craig Doidge | craig@ignitiongroup.co.za | Admin |
| Sean Bergsma | sean@ignitiongroup.co.za | Admin |
| Donovan Bergsma | donovan@ignitiongroup.co.za | Admin |
| Laren Farquharson | laren@ignitiongroup.co.za | Admin |

### ⚠️ Password change required on first login

Every seeded user **must change their password** immediately after first login.

Steps for each user:
1. Navigate to the IGSIGN URL
2. Log in with email + `IgSign2026!`
3. Go to **Account → Settings → Change Password**
4. Set a strong personal password
5. Confirm change

Do not use the default password beyond first login. It is the same for all pilot users and is stored in version control.

---

## NDA Template setup (manual — required before NDA agreements can be sent)

The NDA signing flow requires a DocuSeal template named exactly **`IGSIGN NDA Template`**. This cannot be seeded programmatically — it must be created via the template editor.

Steps:
1. Log in as an admin user
2. Go to `/admin/templates` → **New template** (opens the DocuSeal editor at `/templates/new`)
3. Upload the standard IG NDA PDF
4. Place the following fields on the document:
   - **BU Head**: Signature + Full Name + Date
   - **Finance Director**: Signature + Full Name + Date
   - **CEO**: Signature + Full Name + Date
   - **Counterparty**: Signature + Full Name + Date
5. In the template metadata form, set:
   - **Name:** `IGSIGN NDA Template` ← must match exactly
   - **Kind:** NDA
   - **Status:** Active
6. Save

Until this template exists, any NDA agreement submitted via IGSIGN will fail at the Send step with the error: _"NDA Template has not been configured."_

---

## Smoke test checklist

Run through each flow end-to-end before opening to all pilot users:

- [ ] **Login** — all four pilot users can log in with default password
- [ ] **Password change** — all four users change password successfully
- [ ] **NDA flow** — create new NDA agreement → fills counterparty details → skips upload → review page shows NDA note → Send routes to internal signatories
- [ ] **Upload flow** — create new MSA agreement → upload a PDF → field placement renders → review page shows uploaded file → Send works
- [ ] **DOCX upload** — upload a `.docx` file → converts to PDF without error
- [ ] **Multi-document upload** — upload two files in one agreement → both appear on review page
- [ ] **CAF PDF preview** — Preview CAF link on review page opens the generated PDF
- [ ] **Signing email** — internal signatory receives signing invitation email
- [ ] **Counterparty flow** — after all IG signatories sign, counterparty receives invitation

---

## Rollback

If a critical issue is found post-launch:

1. Re-deploy the previous Docker image tag
2. If migrations were run: `bundle exec rails db:rollback STEP=N` (confirm N with the migration files applied)
3. Notify pilot users via email

---

## Notes

- Pilot accounts are all scoped to the single `Ignition Group` account record created by seed
- All seed operations are idempotent — re-running `db:seed` is safe at any time
- LibreOffice and JRE are included in the Docker image (`libreoffice-headless`, `default-jre-headless`) — DOCX conversion should work without additional setup
