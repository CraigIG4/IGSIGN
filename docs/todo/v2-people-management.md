# V2: Managed People & Entities

**Status:** Deferred — MVP uses `IgSignatories` Ruby constant  
**Priority:** High — required before any organisational change (new hires, departures, role changes)  
**Owner:** TBD  

---

## Current state (v1 / MVP)

Signatory chains are defined as frozen Ruby constants in `lib/ig_signatories.rb`:

```ruby
PEOPLE = {
  sean_bergsma: { name: 'Sean Bergsma', title: 'Group CEO', email: '...', active: true },
  ...
}.freeze

ENTITIES = {
  iti: { bu_heads: %i[william_talbot craig_daroche richard_swart], ... },
  ...
}.freeze
```

**Deactivation** is managed via `config/ig_signatory_overrides.yml` + a rake task:
```
bundle exec rake "igsign:people:deactivate[email@ignitiongroup.co.za]"
```
The change must be committed and redeployed to take effect on Render.

**Limitations of the constant approach:**
- Any people change (hire, departure, role change, entity restructure) requires a code commit and redeploy — no self-service for admins.
- No audit trail of changes.
- No "out of office / temporary delegate" support.
- Cannot be managed by non-developers.

---

## V2 design

### New models

```ruby
# Represents an IG staff member who appears in signing chains.
class IgPerson < ApplicationRecord
  # name, title, email, active (bool), alternate_id (FK self)
  belongs_to :alternate, class_name: 'IgPerson', optional: true
end

# Represents a legal IG entity.
class IgEntity < ApplicationRecord
  # key (slug), name, short_name, registration, address
  has_many :ig_entity_members
  has_many :ig_people, through: :ig_entity_members
end

# Join: person → entity with a role (bu_head, bu_finance, final_operational, final_other).
class IgEntityMember < ApplicationRecord
  belongs_to :ig_entity
  belongs_to :ig_person
  # role: enum [:bu_head, :bu_finance, :final_operational, :final_other]
  # position: integer (ordering within role for multi-head entities)
end
```

### Chain generation

`IgSignatories.chain_for` is replaced by `IgEntity#signing_chain(caf_type)`, which queries `IgEntityMember` with the same logic currently in the Ruby constant.

### Admin UI

- `/admin/ig-people` — CRUD for people (add, deactivate, set alternate)
- `/admin/ig-entities` — CRUD for entities and their member assignments
- Accessible only to `admin` role users

### Migration path

1. Create migrations for `ig_people`, `ig_entities`, `ig_entity_members`
2. Seed from the existing `IgSignatories` constants (one-time migration)
3. Update `chain_for` to query DB instead of constants
4. Remove `lib/ig_signatories.rb` constants (keep module as a thin wrapper for BC)
5. Remove `config/ig_signatory_overrides.yml` — deactivation is now a DB update

### Out of office / temporary delegate (future)

`IgPerson` gets an `out_of_office_until: datetime` field. If set and the datetime is in the future, `chain_for` substitutes the `alternate`. This would allow line managers to mark someone OOO from the admin UI without deactivating them permanently.

---

## Acceptance criteria for v2

- [ ] Admin can add a new person without code changes
- [ ] Admin can deactivate a person — change takes effect immediately (no redeploy)
- [ ] Admin can reassign BU Head role for an entity
- [ ] Audit log records every change (who, what, when)
- [ ] All existing spec coverage in `spec/models/caf_workflow_prepopulation_spec.rb` continues to pass after migration
