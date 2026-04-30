# Findings

Open design/implementation concerns that don't fit `PLAN.md` (intent) or
`STATUS.md` (tracking index). Each finding is a detailed rationale for
work queued in the Rework program in `STATUS.md`. Close a finding by
deleting its section when the matching rework item is completed.

## F12 — `init-fleet.sh` prompt loop does not walk nested map values

**Observation.** The wrapper iterates top-level scalar variables in
`init/inputs.auto.tfvars` and substitutes `__PROMPT__` sentinels via
TTY prompts, but does not descend into nested map values. The
`environments` variable is a map of objects whose values include
`subscription_id` and `hub_network_resource_id` — both of which ship
as `__PROMPT__` per env. On first run, the wrapper prints "Running
terraform apply" and the apply fails on the `validation { condition }`
blocks for `environments.<env>.{subscription_id,hub_network_resource_id}`
because those sentinels were never substituted. The adopter is left
hand-editing the file (or running `sed`) before re-running.

The comment at `init/inputs.auto.tfvars:55` already acknowledges
this — *"The init-fleet.sh prompt flow does not walk nested map
values — fill in GUIDs and hub resource IDs here before running
init"* — but the prompt UX is misleading: the wrapper happily runs
the apply that is guaranteed to fail.

**Risk.** Every adopter hits this on first run. The error surface is
two long Terraform validation errors with stack traces, not a
human-friendly message. Adopters either guess at the file edit or
read source to understand the prompt model.

**Options.**
- **Option A — recursive prompt walk.** Teach the wrapper to descend
  into `map(object(...))` values, prompting per-key per-env. Requires
  parsing HCL (or the schema) at runtime; today the wrapper just
  greps for `__PROMPT__`. Bash + `hcl2json` or a tiny Python helper.
- **Option B — pre-flight refusal.** Have the wrapper grep for any
  remaining `__PROMPT__` after the scalar prompt loop, and if found,
  list the offending lines with file:line references and exit 0
  with instructions ("edit these lines, then re-run") instead of
  invoking `terraform apply`. Smaller change; punts the full UX to
  a future iteration.
- **Option C — flatten the schema.** Replace the `environments` map
  with per-env top-level scalars (`mgmt_subscription_id`,
  `nonprod_subscription_id`, …) so the existing scalar-only prompt
  loop covers everything. Loses the symmetry of the map and makes
  adding new envs (`dev`, `stage`) more invasive.

**Recommendation.** B as a stop-gap (1-day fix; eliminates the
foot-gun), then A as the proper solution.

## F13 — `init-fleet.sh` should prompt for `egress_next_hop_ip`

**Observation.** Every region in `networking.envs.<env>.regions.<r>`
ships with `egress_next_hop_ip: null`. The rendered comment says
*"fill in before first cluster apply in this region"*. In practice
almost every adopter runs hub-and-spoke with a central firewall /
NVA, so this is a near-universal value, not a nice-to-have.

`bootstrap/fleet` accepts `null` (the `0.0.0.0/0` route on
`rt-fleet-<region>` is simply not created), but **Stage 1 fails fast
at cluster apply** in any region whose clusters have hub-routed
egress. The adopter therefore hits the same edit-and-re-apply cycle
on first cluster create that they hit on first init.

**Risk.** Same as F12: discoverability. The TODO comment is in the
rendered yaml, not in the prompt flow, so the adopter only finds it
when Stage 1 errors.

**Options.**
- **Option A — prompt per env-region.** The init flow already knows
  the env list and the `primary_region`; prompt for one
  `egress_next_hop_ip` per env-region. Accept blank → null (opt-out
  for adopters with adopter-managed routing).
- **Option B — single-value shortcut.** Prompt once for "central
  firewall private IP for `<primary_region>`" and apply the same
  value to all 3 envs in that region. Covers the 90% case (one
  central NVA serving all envs in one region); adopters with
  per-env NVAs edit the yaml afterwards. Simpler UX.
- **Option C — group with hub VNet prompt.** When prompting for
  `hub_network_resource_id`, also prompt for the matching
  `egress_next_hop_ip`. Naturally pairs the two values since they
  describe the same hub.

**Recommendation.** C — pair the two prompts. Both are
hub-properties; one prompt block per env-region keeps the UX
linear. Empty input on either field still maps to `null` (opt-out).

This finding interacts with F12: any solution to F13 that prompts
inside the `environments` map requires F12's fix first (today the
wrapper can't descend into the map at all).

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

## F25 — `tf-apply` re-plans from scratch instead of replaying the PR's saved plan

**Observation.** `tf-plan.yaml` already runs `terraform plan -out
plan.tfplan` for stage0 (`tf-plan.yaml:160`) and per-cluster stage1
(`tf-plan.yaml:263`), and uploads each binary plan as a `plan-*`
artefact for the `summarize` job to consume. After merge,
`tf-apply.yaml` discards those artefacts entirely and re-derives the
plan implicitly via `terraform apply -auto-approve` (`tf-apply.yaml:166`
for stage0, `:344` for stage1). The workflow header
(`tf-apply.yaml:6-8`) frames this as deliberate:

> Re-plans fresh on the merge commit rather than replaying the PR's
> plan artefact (safer: base has advanced).

The argument is real but overstated. "Base has advanced" is a problem
only when something **other than the merging PR** modifies state in
the gap between PR plan and post-merge apply. The post-merge concurrency
group (`tf-apply.yaml:37`) already serialises applies, so two
back-to-back PRs cannot interleave their applies. What it cannot
prevent: a manual `terraform apply` against the same backend, or
out-of-band Azure changes (someone clicking in the portal). Both are
operationally rare and detected by `terraform plan` returning a
different diff than the one approved on the PR — which is the exact
**desired** signal: an unreviewed change has slipped in, abort.

The current "re-plan, then apply" pattern silently absorbs that signal:
the post-merge apply just executes whatever the new plan says, even
if it differs from what reviewers approved. There is no diff between
"what was reviewed" and "what was applied" because the reviewed plan
was thrown away.

**Risk.**
1. **Reviewed plan ≠ applied plan.** A reviewer approves PR plan A; in
   the merge window, drift introduces additional changes; post-merge
   apply silently rolls A + drift together. The PR comment showing
   what was approved no longer matches the merge commit's effect on
   infrastructure.
2. **Non-determinism in the apply pipeline.** Two retries of the same
   `tf-apply` run can produce different applies if state changed
   between attempts. With saved-plan replay, retry behaviour is
   deterministic: `terraform apply plan.tfplan` either succeeds or
   refuses (state changed under the plan), instead of re-deriving and
   silently doing something different.
3. **Wasted compute.** Every apply re-runs the full plan that the PR
   already produced. For stage1 with N clusters, that's 2N plan
   invocations (PR + post-merge) where N would suffice.

**Options.**

- **Option A — replay the PR's saved plan with stale-plan abort.**
  Post-merge `tf-apply` downloads the plan artefact from the
  associated PR's `tf-plan` workflow run (e.g. via
  [`dawidd6/action-download-artifact`](https://github.com/dawidd6/action-download-artifact)
  with `workflow=tf-plan.yaml`, `pr=${{ github.event.pull_request.number }}`,
  or for `push`-on-main events, by walking back from
  `${{ github.event.before }}..${{ github.sha }}` to find the squash-
  merged PR), then runs `terraform apply plan.tfplan` directly. If
  state has drifted under the plan, Terraform refuses with "Saved plan
  is stale" and the apply fails loudly — exactly the desired signal.
  The operator's recovery is to re-run `tf-plan` on a hot-fix branch,
  re-review, and re-merge.

- **Option B — re-plan, but compare against the saved plan and abort
  on drift.** Post-merge `tf-apply` downloads the PR's plan, runs a
  fresh `terraform plan -out plan-new.tfplan`, then `diff <(terraform
  show -no-color plan.tfplan) <(terraform show -no-color
  plan-new.tfplan)` and aborts if they differ. More moving parts; the
  diff is not 1:1 because timestamps and ordering can shift, so this
  needs `tf-summarize -json` or similar canonicalisation. Heavier than
  A and largely re-implements what saved-plan replay gives for free.

- **Option C — keep current behaviour; document the trade-off
  explicitly.** Cheapest. The `tf-apply.yaml:6-8` header comment
  already does this informally; promote to a `PLAN.md §10` subsection
  so reviewers know not to expect plan-faithful applies. Doesn't
  address the reviewed-plan ≠ applied-plan risk.

**Recommendation.** **Option A.** The "base has advanced" worry is
better addressed by Terraform's own stale-plan check than by silently
re-planning. The PR-to-merge-commit lookup logic for `push` events is
a one-time CI investment (action-download-artifact handles most of
it). The change replaces "post-merge apply silently does whatever the
current state implies" with "post-merge apply executes the reviewed
plan or refuses".

**Cross-references.**
- `tf-plan.yaml:164` (stage0 plan upload), `:298` (stage1 plan upload).
- `tf-apply.yaml:6-8` (header rationale to revise),
  `tf-apply.yaml:161-166` (stage0 apply step),
  `tf-apply.yaml:340-344` (stage1 apply step).
- PLAN §10 "CI" — currently silent on plan provenance; should call out
  the saved-plan replay contract once Option A lands.

**Note — apply must gate on plan availability.** Whichever option
lands, `tf-apply` must short-circuit when no plan artefacts are
present for the merging commit. The `tf-plan` workflow is path-
filtered (`tf-plan.yaml:26-44`), so a PR that touches only docs,
`.github/workflows/tf-apply.yaml` itself, or other unwatched paths
produces zero plans; today's "re-plan inside apply" pattern hides
this by always re-deriving from current state, which means a
docs-only push-to-main can in principle still apply if state has
drifted out of band. Under Option A the apply leg should:

1. Download the merging PR's plan artefacts (zero or more — there is
   one stage0 plan plus one stage1 plan per affected cluster, so the
   set is naturally a list, not a single file).
2. If the downloaded set is empty, log "no plans for this merge;
   skipping apply" and exit success. The matrix-skip pattern is the
   same one already used by `tf-plan.yaml`'s `cluster` job (matrix
   built from `needs.detect.outputs.clusters`, which can be `[]`).
3. Otherwise apply each plan in order: stage0 first (single plan),
   then stage1 per-cluster (matrix over the downloaded set, not over
   `detect-affected-clusters` re-run on main — the PR's plan set IS
   the source of truth).

This mirrors the empty-artefact guard added to `tf-plan.yaml`'s
`summarize` job (commit `16e0038` on PR #2): "the workflow ran" is
not the same as "there is something to apply".

