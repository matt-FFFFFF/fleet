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

## F14 — `init-fleet.sh` must prompt for `primary_region`

**Observation.** `init/inputs.auto.tfvars` ships
`primary_region = "eastus"` as a hard-coded default with no
`__PROMPT__` sentinel, so the wrapper never asks. The renderer uses
this value as the only region key under
`networking.envs.<env>.regions.<r>` for every env, and it is also
where every fleet-shared resource (ACR, fleet KV, tfstate SA) lands
via `acr.location` / `keyvault.location`.

In practice the adopter's hub VNet, BYO Private DNS Zones, and
Azure subscriptions are typically in a single chosen region that is
**not** `eastus`. During this walkthrough the hub VNet was in
`swedencentral`, which means the rendered yaml had to be hand-edited
(`sed`) to match before re-running, because VNet peering rejects
cross-region peers. Today the only signal that the default is wrong
is a Terraform error at `bootstrap/fleet` apply time
(`mgmt_vnet_ids[acr.location]` membership check) or, worse, a
peering failure deep in the apply.

**Risk.** Same class as F12/F13 — discoverability. The default is
a foot-gun rather than a sensible fallback because most adopters'
infrastructure is regional and `eastus` is just "the first region
GitHub Actions runners spin up in fastest." Hand-editing the
rendered yaml after init is also error-prone: the value appears in
multiple keys (`acr.location`, `keyvault.location`, every
`networking.envs.<env>.regions.<r>` key, `envs.mgmt.location`).

**Options.**
- **Option A — prompt with `eastus` as default-suggested.** Add the
  `__PROMPT__` sentinel; show `eastus` as the default in the prompt
  text so adopters who genuinely want it can press enter. Tiny
  change.
- **Option B — derive from hub VNet.** When the hub VNet ARM id is
  prompted (per env-region), parse `az resource show` to extract
  the VNet's `location` and use it. Eliminates the foot-gun
  entirely but couples init to live Azure auth.
- **Option C — validate fail-fast at init time.** Keep the default
  but, when any `hub_network_resource_id` is set, run `az resource
  show --query location -o tsv` and refuse to proceed if the hub
  region differs from `primary_region`. Catches the mistake before
  Terraform sees it.

**Recommendation.** A — prompt with `eastus` as the suggested
default. Cheapest fix, immediately removes the silent-default
foot-gun, and is independent of F12/F13 because `primary_region`
is a top-level scalar (the existing prompt loop already handles
those).

## F15 — Vendored `github-repo` module emits deprecated-attribute warnings on plan

**Observation.** `terraform plan` on `bootstrap/fleet` surfaces five
deprecation warnings sourced from
`terraform/modules/github-repo/`:

- `github_repository.vulnerability_alerts` — provider says "use the
  `github_repository_vulnerability_alerts` resource instead. This
  field will be removed in a future version" (3 occurrences across
  the fleet repo + the 3 GitHub App-authored bootstrap repos).
- `github_actions_environment_secret.plaintext_value` referenced in
  an `ignore_changes` list — provider says the attribute is
  deprecated (2 occurrences).

**Risk.** Today these are warnings only — plan/apply succeed. When
the provider drops the deprecated attributes (likely the next
major), `terraform plan` will hard-fail until the vendored module is
updated. We are pinned via `~> X.Y` so the failure won't surprise
us until we deliberately bump, but the bump will then be blocked on
the module fix.

The module is vendored (a fork of the AVM `github-repo` module) and
lives under our `modules/`, so the fix has to land in this repo —
upstream may or may not have addressed it. PLAN §16 / Stage -1
already documents the vendor relationship.

**Options.**
- **Option A — fix the warnings now.** Replace
  `vulnerability_alerts = var.vulnerability_alerts` on the
  `github_repository` resource with a separate
  `github_repository_vulnerability_alerts` resource keyed by
  `repository = github_repository.this[0].name`. Drop
  `plaintext_value` from the `ignore_changes` list (the provider
  has replaced the input shape).
- **Option B — track upstream and rebase the vendor.** If the AVM
  module has already migrated, a re-vendor is cheaper than
  hand-fixing.
- **Option C — defer.** Leave it until the next github provider
  major bump forces the issue.

**Recommendation.** B if upstream is fixed; A otherwise. Either way
it's a low-priority cleanup — the PR can be small and
self-contained. Stage 0+ doesn't touch this module so the blast
radius is limited to `bootstrap/fleet` and `bootstrap/team`.

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

## F17 — `bootstrap/fleet` does not grant the operator Key Vault data-plane access

**Observation.** `bootstrap/fleet` creates the fleet Key Vault in
RBAC mode (`enableRbacAuthorization = true`) with
`defaultAction = "Deny"` and a private endpoint. In the same apply
it then writes the `fleet-runners-app-pem` secret via
`azapi_data_plane_resource.fleet_runners_pem_secret` (a data-plane
PUT to `<vault>.vault.azure.net`).

The only RBAC assignment the stage issues on the new vault is
`Key Vault Secrets User` to `uami-fleet-runners` (line
`main.kv.tf:144`) — read-only, scoped to the runner UAMI. The
**operator running the apply** receives no role on the vault, so
the data-plane PUT fails with `403 Forbidden` /
`AccessDenied: Caller is not authorized to perform action on
resource`.

**Risk.** First-apply blocker for every adopter. The vault exists,
the PE + DNS zone group exists, the runner UAMI has `Secrets User`,
but the operator can't seed the PEM that the runner needs to start.
Subsequent applies after the role is granted out-of-band would
succeed, but PLAN §16 / §5.2 frames `bootstrap/fleet` as a
single-shot first-apply, so the failure is dead-on-arrival for a
fresh adopter.

**Options.**
- **Option A — assign Key Vault Secrets Officer to the operator
  inside `bootstrap/fleet`.** Add an `azapi_resource` role
  assignment whose `principalId` resolves to the signed-in caller
  (`data.azurerm_client_config.current.object_id` or the equivalent
  via the azuread provider). Scope: the new vault. Role:
  `Key Vault Secrets Officer` (or `Key Vault Administrator` if we
  ever need to manage keys/certs from this stage too). Drop the
  role on second apply once a CI principal takes over, or leave it
  in for re-apply convenience. Depends on a `data` lookup of the
  signed-in principal — the providers we already pin (`azuread` +
  `azurerm` via `azapi`) can supply that.
- **Option B — use a CMK / managed-identity-only path for the PEM.**
  Don't have the operator write the PEM at all; have a separate
  out-of-band step (e.g. `init-gh-apps.sh` posts the PEM directly to
  the vault). Avoids the role-grant in TF but pushes the
  reachability requirement (private endpoint, VNet connection) onto
  a non-Terraform tool. Higher operational complexity for no real
  blast-radius win — the operator already has tenant-admin and
  Owner at this point.
- **Option C — keep the public endpoint open during first apply.**
  We already have the `allow_public_state_during_bootstrap` escape
  hatch for the tfstate SA; an analogous flag on the KV would let
  the operator's public IP write the secret over the public
  endpoint (with `defaultAction: Deny` blocking everyone else). It
  re-introduces a public-endpoint exposure window and doesn't fix
  the role-grant problem (RBAC still rejects the caller without
  Secrets Officer). Worse than A.

**Recommendation.** A. The operator running `bootstrap/fleet` is
already privileged (Owner at root, Privileged Role Administrator in
Entra) — granting them `Secrets Officer` on the vault they just
created is not a privilege escalation, it just makes the stage
self-sufficient. The role assignment is the same shape as the
existing runner-UAMI grant; ~10 lines of HCL. After the bootstrap
is stable, this can be narrowed to "operator only on first apply"
via a `count = var.allow_operator_kv_writes ? 1 : 0` toggle if we
care about the long-tail.

Workaround for the current walkthrough: grant
`Key Vault Secrets Officer` manually before re-applying:

```sh
KV_NAME=$(az keyvault list --query "[?starts_with(name,'kv-scopfleet')].name | [0]" -o tsv)
KV_ID=$(az keyvault show -n "$KV_NAME" --query id -o tsv)
az role assignment create \
  --assignee "$(az ad signed-in-user show --query id -o tsv)" \
  --role "Key Vault Secrets Officer" \
  --scope "$KV_ID"
# Wait ~30s for the assignment to propagate, then re-run:
terraform apply tfplan.bootstrap-fleet
```

## F18 — `_fleet.yaml` template omits `dns_servers` from the per-region schema example

**Observation.** `networking.envs.<env>.regions.<region>.dns_servers`
is a fully-supported, schema-validated field. It is plumbed end-to-
end:

- `terraform/modules/fleet-identity/main.tf:147` derives it with a
  `tolist([])` default-on-absent/null
- `terraform/modules/fleet-identity/outputs.tf:56` exposes it on
  `networking_derived.envs.<k>.dns_servers`
- `terraform/bootstrap/fleet/main.network.tf:239` and
  `terraform/bootstrap/environment/main.network.tf:246` pass it
  through to the AVM `virtual_networks` module
- Passthrough is covered by unit tests at
  `terraform/modules/fleet-identity/tests/unit/fleet_identity.tftest.hcl:776,807,848`

But the rendered `clusters/_fleet.yaml` — the single source of truth
that adopters edit post-init — never mentions the field. The
per-region commented schema block at `init/templates/_fleet.yaml.tftpl:86-117`
documents `address_space`, `egress_next_hop_ip`,
`hub_network_resource_id`, and `create_reverse_peering`, then the
loop body at lines 124-135 emits exactly three keys per region. An
adopter who needs custom DNS (a hub-resolver pattern, on-prem
forwarders, Azure Private DNS Resolver inbound endpoints) has no
discoverable signal from `_fleet.yaml` that the field exists; they
have to read `PLAN.md:413` or `docs/adoption.md:301` to find it.

**Risk.** Adopters silently fall back to Azure-provided DNS
(168.63.129.16) even when their environment requires forwarder-
based resolution. Symptoms surface late: AKS DNS lookups for
on-prem hostnames fail at workload deploy time, long after
`bootstrap/{fleet,environment}` has succeeded. The fix is a
one-line yaml edit, but only if the adopter knows the field
exists.

`address_space`, `egress_next_hop_ip`, and `hub_network_resource_id`
are also documented inline in the rendered file — `dns_servers` is
the only first-class per-region field that isn't, which makes its
omission a documentation bug, not a design choice.

**Options.**
- **Option A — extend the schema comment + emit the field commented-
  out.** Add a `dns_servers` paragraph to the per-region comment
  block at `init/templates/_fleet.yaml.tftpl:86-117` (alongside
  `address_space` etc.), and emit the key in the loop body as a
  commented line: `# dns_servers: []  # default = Azure-provided DNS`.
  No prompt — `[]` is the right default for adopters without a
  hub resolver, and adding a prompt would force every adopter to
  answer a question that doesn't apply to most. Pure documentation
  fix.
- **Option B — emit the field uncommented with `[]`.** Same as A but
  the key is live, not commented. Slightly more discoverable
  (`grep dns_servers _fleet.yaml` finds it) but adds visual noise
  to the common case.
- **Option C — leave as-is, document in adoption.md instead.**
  Already partially done at `docs/adoption.md:301`. Doesn't solve
  the discoverability problem — adopters reading
  `clusters/_fleet.yaml` to figure out what's editable will still
  miss it.

**Recommendation.** A. The per-region schema comment is already the
right place for this; we just have to add the paragraph. Match the
prose style of the existing `egress_next_hop_ip` /
`hub_network_resource_id` paragraphs. Roughly:

```
#   dns_servers              VNet-level DNS servers for this env-
#                            region's spoke VNet. Empty list (the
#                            default) means Azure-provided DNS
#                            (168.63.129.16). Set to a list of
#                            hub-resolver IPs when this env-region
#                            requires forwarder-based resolution
#                            (on-prem hostnames, Azure Private DNS
#                            Resolver inbound endpoints, etc.).
```

and emit `# dns_servers: []` in the loop body next to
`egress_next_hop_ip`.

## F19 — `_fleet.yaml` template omits `hub_peering` from the per-region schema example

**Observation.** `networking.envs.<env>.regions.<region>.hub_peering`
is a nested object with at least one supported field —
`use_remote_gateways` (bool, default `false`). It is plumbed end-to-
end:

- `terraform/modules/fleet-identity/main.tf:133` derives
  `use_remote_gateways = try(region_block.hub_peering.use_remote_gateways, false)`
- `terraform/modules/fleet-identity/outputs.tf:55` exposes it on
  `networking_derived.envs.<k>.use_remote_gateways`
- `terraform/bootstrap/fleet/main.network.tf:309` and
  `terraform/bootstrap/environment/main.network.tf:269` pass it
  through to `hub_peering_options_tohub.use_remote_gateways` on the
  spoke→hub peering
- Passthrough is covered by unit tests at
  `terraform/modules/fleet-identity/tests/unit/fleet_identity.tftest.hcl:774,802,843`

But the rendered `clusters/_fleet.yaml` — like F18's `dns_servers` —
never mentions the field. The per-region commented schema block at
`init/templates/_fleet.yaml.tftpl:86-117` documents `address_space`,
`egress_next_hop_ip`, `hub_network_resource_id`, and
`create_reverse_peering`; the loop body at lines 124-135 emits
exactly three keys per region; `hub_peering` is absent in both
places.

The failure mode is sharper than F18. An adopter who needs gateway
transit (the common case for any hub with an ExpressRoute or VPN
gateway) reads `docs/adoption.md:294`, `PLAN.md:404`, or skims the
schema, decides to set the field, and — without an example to copy
— frequently writes it at the wrong nesting level:

```yaml
networking:
  envs:
    mgmt:
      regions:
        swedencentral:
          ...
          use_remote_gateways: true   # WRONG — top-level
```

The schema's `try(region_block.hub_peering.use_remote_gateways, false)`
silently falls back to `false`, the plan succeeds, the peering is
created with `useRemoteGateways = false`, and the next adopter to
update the same region sees a confusing in-place diff:

```
~ useRemoteGateways = true -> false
```

— because their first-correct edit is being reverted by the same
nesting bug on every subsequent apply. This was hit during the
adoption walkthrough (the operator had to re-nest the field under
`hub_peering`).

**Risk.** Adopters with hub gateways silently get island-VNet
behaviour. Symptoms surface late: VPN clients can't reach spoke
PEs, ExpressRoute routes don't propagate, on-prem→spoke traffic
fails. The fix is a one-line yaml re-nest, but only if the adopter
realises their first attempt was at the wrong level. Easy to spend
hours debugging routing before suspecting the yaml shape.

**Options.**
- **Option A — extend the schema comment + emit `hub_peering` commented-
  out.** Add a `hub_peering.use_remote_gateways` paragraph to the
  per-region comment block at
  `init/templates/_fleet.yaml.tftpl:86-117` (alongside
  `egress_next_hop_ip` etc.), and emit the block in the loop body
  as commented lines:
  ```yaml
          # hub_peering:
          #   use_remote_gateways: false   # set true for hub gateway transit
  ```
  No prompt — `false` is the right default for adopters without a
  hub gateway, and adding a prompt would force every adopter to
  answer a question that doesn't apply to most. Pure documentation
  fix. Same shape as F18 Option A.
- **Option B — emit the block uncommented with the default value.**
  Slightly more discoverable but adds visual noise to the common
  case. Same trade-off as F18 B.
- **Option C — fail fast on unknown top-level region keys.** Add a
  `validation { condition }` to the bootstrap stage that rejects any
  region-level key not in the known set (`address_space`,
  `egress_next_hop_ip`, `hub_network_resource_id`,
  `create_reverse_peering`, `dns_servers`, `hub_peering`,
  `subnet_route_table_ids`). Catches the wrong-nesting bug at plan
  time with a precise error. Independent of A/B — wants both.

**Recommendation.** A + C. Documentation alone (A) is the same fix
as F18 and is necessary regardless. But the silent-fallback failure
mode is sharp enough that a structural guard (C) earns its keep:
detecting `use_remote_gateways` (or any other unknown key) at the
top of a region block and refusing the plan with
`"unknown key 'use_remote_gateways' on networking.envs.<env>.regions.<region>: did you mean hub_peering.use_remote_gateways?"`
saves the hours-of-debugging path entirely. The same guard would
catch future schema mistakes (typos in `egress_next_hop_ip`,
mis-nested `dns_servers`, etc.) for free.

## F24 — Workflow runs-on split between `ubuntu-24.04` and `[self-hosted]` is undocumented

**Observation.** The five workflows use a mixed runner model:

| Workflow | Job | runs-on |
| --- | --- | --- |
| `validate.yaml` | terraform fmt, tflint, yamllint, subnet slots, naming parity | `ubuntu-24.04` |
| `tf-plan.yaml` | detect affected | `ubuntu-24.04` |
| `tf-plan.yaml` | stage0 plan, per-cluster matrix | `[self-hosted]` |
| `tf-plan.yaml` | summarize plans | `ubuntu-24.04` |
| `tf-apply.yaml` | detect affected | `ubuntu-24.04` |
| `tf-apply.yaml` | stage0 apply, publish stage0 outputs, per-cluster matrix | `[self-hosted]` |
| `env-bootstrap.yaml` | initialisation guard | `ubuntu-24.04` |
| `env-bootstrap.yaml` | bootstrap | `[self-hosted]` |
| `team-bootstrap.yaml` | detect new teams | `ubuntu-24.04` |
| `team-bootstrap.yaml` | bootstrap matrix | `[self-hosted]` |

The split is functional but unprincipled in writing: utility/lint/
detect jobs run on GitHub-hosted, anything that needs Azure OIDC +
private network reachability runs on the fleet self-hosted pool.
Neither `PLAN.md` nor any workflow header comments state this
contract. An adopter reading the workflows cannot tell whether a
specific job *requires* `ubuntu-24.04` (for some toolchain reason)
or merely defaults to it (because nothing forced it onto self-
hosted), and therefore cannot reason about migration to all-self-
hosted.

**Risk.**

- Adopters who want a single-runner-pool trust boundary (one place
  to audit, one image to harden, one egress path) cannot tell from
  the workflows whether moving everything to `[self-hosted]` is
  safe or breaks a hidden assumption.
- The runner pool becomes the only path to CI: a misconfigured
  pool means *all* CI is broken, not just Azure-touching jobs.
  Today a broken pool still leaves lint/fmt/detect green, which is
  useful diagnostic signal.
- Bootstrap is bootstrapping. `bootstrap/fleet` is the stage that
  *creates* the runner pool; running its plan via a workflow that
  itself depends on the runner pool is impossible. That stage is
  always laptop-applied (PLAN §4 Stage -1). Subsequent runner-pool
  edits flow through `tf-plan` / `tf-apply` on `[self-hosted]` —
  which means a runner-pool change that breaks the pool also
  breaks its own rollback. Recovery is laptop-apply.

**Options.**

A. Keep the split, document it. Add a short header comment to each
   workflow stating *why* utility jobs use `ubuntu-24.04` (kept
   functional even when the runner pool is broken; no Azure
   secrets needed; faster cold-start than KEDA scale-from-zero)
   and *why* Azure-touching jobs use `[self-hosted]` (private
   network access to KV/PE-only resources; OIDC federated identity
   bound to the fleet runner UAMI). Encode the contract in
   `PLAN.md` §10 ("CI" section) so it's normative, not implicit.

B. Move all jobs to `[self-hosted]`. Eliminates the split. Trades
   off: lint/fmt/detect outage when the runner pool is down (no
   diagnostic signal); cold-start latency on every PR (currently
   ~1–2 min for KEDA scale-from-zero, paid only on `tf-plan`
   matrix legs). Requires verifying the runner image bundles the
   six tools utility jobs need (`terraform`, `jq`, `yq`, `tflint`,
   `yamllint`, `awk`/`sed`/`find`) and that `actions/setup-*`
   actions work on the container-based runner with a writable
   toolcache.

C. Move utility jobs to `[self-hosted]` but keep bootstrap-stage
   workflows (`env-bootstrap`, `team-bootstrap`) on
   `ubuntu-24.04`. Reasoning: bootstrap operations are the
   recovery path when self-hosted is broken; they should never
   depend on it. Mixed model but principled.

D. Self-hosted by default with a `runs_on_override` workflow_dispatch
   input on each workflow, falling back to `ubuntu-24.04`. Runtime-
   selectable. More moving parts; signals "self-hosted is the
   default but recoverable", which matches the operational reality.

**Recommendation.** **Option A for now.** The current split is
sound; the gap is purely documentary. Until adopters have actually
exercised post-bootstrap `tf-plan` / `tf-apply` flows on a working
self-hosted pool (and we have data on cold-start cost, image
completeness, and recovery friction), inverting the default
without that signal is premature. After Stage 1 lands and we have
real PR latency numbers, revisit B vs. C vs. D.

**Where.**

- `PLAN.md` §10 "CI": add a "Runner placement" subsection with
  the contract.
- Each `.github/workflows/*.yaml` file: 3–5 line header comment
  citing the rule.
- `docs/adoption.md` §5.1 (or wherever the runner pool is first
  introduced to the adopter): one paragraph on what self-hosted
  protects (Azure OIDC + private network) and what it doesn't
  (lint/fmt/detect, bootstrap recovery).

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

