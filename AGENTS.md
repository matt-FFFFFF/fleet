# Agent onboarding

You (future agent) are entering a plan-driven codebase. Read this file in
full before proposing or writing any change.

## Source of truth

- **`PLAN.md`** is **the** source of truth for intent, design, and
  deviations. It answers "what should be." Sections are stable and
  numbered; cite them when explaining work (e.g. "per §4 Stage 0").
  When an implementation deviates from PLAN, record the deviation in a
  short *Implementation status* paragraph at the top of the affected
  section (PLAN §16 is the reference pattern). Do not rewrite PLAN
  opportunistically.
- **`STATUS.md`** is a **tracking aid** for the plan — a one-line-per-
  sub-item index mirroring PLAN's section numbers. It is **not**
  exhaustive and is **not** a changelog: routine file-level edits,
  refactors, and in-progress commits do not need to appear here.
  Update it when a PLAN sub-item advances (`[ ]` → `[~]` → `[x]`) or
  when reading the current state of a sub-item would otherwise require
  re-deriving it from the tree. If in doubt about whether a change
  belongs in STATUS, it probably doesn't.
- **`docs/naming.md`** is the derivation contract between
  `terraform/config-loader/load.sh` and bootstrap-stage HCL locals. Both
  implementations must agree; change both together or don't change
  either.
- **`docs/adoption.md`** is the adopter-facing guide — edit when the
  adoption flow changes.

## Workflow rules

1. **Orient first.** Before proposing work:
   - `git log --oneline -20`
   - Read the relevant PLAN section(s).
   - Read the matching STATUS lines.
   - Read any "Implementation status" callout inside the relevant PLAN
     section (e.g. PLAN §16 has one).
2. **Keep PLAN clean.** PLAN records intent. Never sprinkle progress
   checkboxes across it. If the implementation deviates from PLAN, add
   a short *Implementation status* paragraph at the top of the affected
   section AND update STATUS.md. §16 is the reference pattern.
3. **Update STATUS in the same commit.** Any commit that closes or
   advances a PLAN sub-item updates the matching line in STATUS.md as
   part of the same commit. Partial progress uses `[~]`.
4. **One source for fleet identity.** Adopter identity lives in
   `clusters/_fleet.yaml` (rendered by `init/` on first run). Bootstrap
   and stage TF `yamldecode(file(...))` it. **Never** reintroduce
   `var.fleet` / `var.environment` or duplicate subscription IDs.
5. **Naming derivation parity.** If you touch a name derivation rule,
   touch all three: `docs/naming.md`, `config-loader/load.sh`, and
   the HCL `local.derived` in the affected bootstrap/stage module.
6. **Version constraints.** Pessimistic-minor everywhere
   (`~> X.Y`). Terraform: `~> 1.9`. Providers pinned in
   `providers.tf` per module; see existing files for the set.
7. **Template machinery is self-destructing.** `init/`, `init-fleet.sh`,
   `.github/workflows/template-selftest.yaml`,
   `.github/workflows/status-check.yaml`, `.github/fixtures/` are deleted
   by `init-fleet.sh` in adopter repos. Don't add production logic to
   any of them — they don't exist post-init.

## Repo geography (quick map)

```
PLAN.md                   spec
STATUS.md                 state (this index)
AGENTS.md                 you are here
init/                     throwaway TF: renders clusters/_fleet.yaml on first run
init-fleet.sh             adopter initializer (wrapper around init/)
clusters/
  _fleet.yaml             single source of truth (generated; edit directly post-init)
  _defaults.yaml          fleet-wide cluster defaults
  {mgmt,nonprod,prod}/    per-env scopes; cluster.yaml under <region>/<name>/
terraform/
  bootstrap/{fleet,environment,team}/  Stage -1
  stages/{0-fleet,1-cluster,2-bootstrap}/  Stage 0/1/2
  modules/                             reusable modules
  config-loader/load.sh                yq deep-merge → tfvars.json
docs/
  adoption.md naming.md                contracts
  onboarding-*.md upgrades.md promotion.md   operator UX
.github/
  workflows/                           CI
```

## Anti-patterns (do not do)

- Adding provider resources to `init/` — it is a renderer, not infra.
- Re-duplicating subscription IDs into env `_defaults.yaml`.
- Hard-coding fleet name in TF (`local.fleet.name` / derived only).
- Silent PLAN edits without a corresponding STATUS update.
- Running `terraform apply` on `bootstrap/*` without the adopter
  explicitly requesting it; these affect live tenants.

## When unsure, ask

Ambiguity in PLAN is worth a clarifying question to the user before
writing code. Preserving PLAN's intent is more valuable than shipping
a plausible guess.
