# Findings

Open design/implementation concerns that don't fit `PLAN.md` (intent) or
`STATUS.md` (tracking index). Each finding is a detailed rationale for
work queued in the Rework program in `STATUS.md`. Close a finding by
deleting its section when the matching rework item is completed.

## F16 — Globally-unique resource names should carry a random suffix

**Observation.** Several resources in the fleet derive names from
`fleet.name` alone, where Azure (or GitHub) requires the name to be
globally unique across all tenants. The current derivations bake the
adopter's chosen `fleet.name` slug straight into the name with no
disambiguator:

- `st<fleet.name>tfstate` — Storage Account (24 char limit, global).
- `acr<fleet.name>shared` — Container Registry (50 char limit, global).
- `kv-<fleet.name>-fleet` — Key Vault (24 char limit, soft-delete
  retention means deleted-vault-not-yet-purged also blocks the
  name for 7-90 days).
- DNS-published private zones under `<fleet_root>` are scoped, but
  any public-facing endpoint (Grafana NSP if the public profile is
  ever enabled, etc.) will hit the same problem.

If two adopters pick the same `fleet.name` — or the same adopter
re-bootstraps after a tear-down before soft-deleted resources purge
— the second `terraform apply` fails with `StorageAccountAlreadyTaken`
/ `RegistryNameAlreadyExists` / `VaultAlreadyExists` errors.

**Risk.** The adopter must either:
1. Pick a uniquely-prefixed `fleet.name` (defeats the purpose of a
   short slug used everywhere in resource naming), or
2. Set the `*_override` escape hatches in `_fleet.yaml` for every
   collision (acr.name_override, keyvault.name_override,
   state.storage_account_name_override) and pick globally-unique
   strings by hand, or
3. Wait out the soft-delete window on a re-bootstrap.

The naming-derivation contract (`docs/naming.md` +
`config-loader/load.sh` + bootstrap HCL `local.derived`) is
explicitly the source of truth for these names, so this is a
contract change, not a one-off resource fix.

**Options.**
- **Option A — random 4-char suffix at init time.** `init/` already
  renders `_fleet.yaml` from a template; have it generate a 4-char
  random suffix once and bake it into the relevant `*_override`
  fields (`st<fleet.name><sfx>tfstate`,
  `acr<fleet.name><sfx>shared`, `kv-<fleet.name>-<sfx>`). The
  override path already exists; this just populates it
  automatically. Stable across re-runs because it lives in the
  rendered yaml and is committed.
- **Option B — derive from `fleet.tenant_id`.** Hash
  `<fleet.name>-<tenant_id>` to a 4-6 char suffix. Deterministic
  per tenant — re-bootstraps in the same tenant pick the same
  name, so the soft-delete-blocking case still hits. Worse than A.
- **Option C — surface the collision earlier.** Add a `terraform`
  precondition on each globally-unique resource that checks the
  name against the relevant ARM "name availability" API
  (`Microsoft.Storage/checkNameAvailability` etc.) at plan time.
  Doesn't fix the collision; just turns a slow apply-time failure
  into a fast plan-time failure. Useful as a complement to A, not
  a replacement.

**Recommendation.** A — `init/` writes a 4-char random suffix into
the three `*_override` fields the first time it runs. Adopters who
want to pick their own names can edit the rendered yaml before
committing (the overrides are already adopter-editable). The 4-char
suffix fits the 24-char Storage Account / Key Vault budgets:
`st<8-char-fleet><4-char-sfx>tfstate` = 8 + 12 + 7 = 27 if the
fleet name is 8 chars; we'd need to tighten the `fleet_name`
length validator from 12 to 8 chars to make it always fit, or
drop the `tfstate` / `shared` suffixes from those names. Both are
contract changes and need a coordinated `naming.md` +
`load.sh` + `local.derived` update across the bootstrap stages.
