# Findings

Open design/implementation concerns that don't fit `PLAN.md` (intent) or
`STATUS.md` (tracking index). Each finding is a detailed rationale for
work queued in the Rework program in `STATUS.md`. Close a finding by
deleting its section when the matching rework item is completed.

## F2 — Replace `Entra AppAdmin` on `fleet-stage0` with Graph `Application.ReadWrite.OwnedBy`

Tracked: Rework item 14. Also fixes a latent bug.

**Observation.** `fleet-stage0` holds the Entra directory role
`Application Administrator`, granting tenant-wide CRUD on every AAD
application in the tenant. Stage 0's actual need is managing exactly
two apps — `argocd` and `kargo` — that it creates itself. The grant is
far broader than required.

**Constraint.** Stage 1 (mgmt cluster only) and Stage 2 (every
cluster) also write to those same apps under different UAMIs:

| Stage | Principal | Operation on Argo/Kargo AAD apps |
|---|---|---|
| Stage 0 | `uami-fleet-stage0` | Create app + SP; write Argo 60d password |
| Stage 1 mgmt | `uami-fleet-mgmt` | Write Kargo 60d password (Stage 0-owned app) |
| Stage 2 every cluster | `uami-fleet-<env>` | Write per-cluster FIC on Argo app; FIC on Kargo app (mgmt only) |

**Target role.** `Application.ReadWrite.OwnedBy` (Graph app-role
`18a4783c-866b-4cc7-a460-3d5e5662c884`):

- Creator auto-owns on create.
- Read/update/delete allowed on apps where the principal is an owner.
- `passwordCredentials` and `federatedIdentityCredentials` are
  owner-scoped operations.
- Cannot touch apps the principal doesn't own.

**Latent bug.** `stages/1-cluster/main.kv.tf:48` comment already
states "requires `Application.ReadWrite.OwnedBy` on the Stage 0-owned
app", but today the `owners` list on `azuread_application.kargo` in
`stages/0-fleet/main.aad.tf` is only `try(local.aad.kargo.owners, [])`
— adopter-supplied human AAD object IDs. `fleet-mgmt` UAMI is not an
owner. The first mgmt Stage 1 apply would fail on the Kargo password
write with a Graph permission error. Refactor fixes this as a
side-effect.

**Refactor surface.**

a. **`terraform/bootstrap/fleet/main.identities.tf`** — replace
   `azuread_directory_role_assignment.stage0_app_admin` with an
   `azuread_app_role_assignment` on the Graph service principal
   (`00000003-0000-0000-c000-000000000000`) granting
   `Application.ReadWrite.OwnedBy` to the `fleet-stage0` UAMI.

b. **`terraform/bootstrap/environment/main.github.tf`** — grant the
   same Graph app-role to each `fleet-<env>` UAMI. Needed so Stage 2
   can write per-cluster FICs on the Argo app; on the mgmt env, also
   needed so Stage 1 can write the Kargo 60d-rotated password.

c. **`terraform/stages/0-fleet/main.aad.tf`** — extend the `owners`
   list on both `azuread_application.argocd` and `azuread_application.kargo`
   (and on the corresponding `azuread_service_principal` resources)
   to:
   `concat(try(local.aad.<app>.owners, []), [self_principal_id], env_uami_principal_ids)`.
   Self-reference ensures Stage 0 can re-apply; env UAMI inclusion
   ensures downstream stages can write their owner-scoped operations.

d. **Stage 0 new inputs.**
   - `fleet_stage0_principal_object_id` — the Stage 0 UAMI's own
     AAD object id, for the self-reference in `owners`.
   - `fleet_env_uami_principal_object_ids` (set of strings) —
     published by `bootstrap/environment` as a repo variable so
     Stage 0 can re-apply with fresh env additions without manual
     wiring.

**Why it's worth doing.** Principle of least privilege. A compromised
`fleet-stage0` with `Application Administrator` can rewrite redirect
URIs on unrelated apps or add secrets to arbitrary SPs across the
tenant. With `Application.ReadWrite.OwnedBy` and a 2-app owner set,
the same compromise is scoped to the fleet's own apps.

**Risk.** `Application.ReadWrite.OwnedBy` as a Graph app-role
assignment requires tenant admin to create — same one-shot cost as
the directory-role grant it replaces, no regression in operator
burden.

## F5 — `.gh-apps.auto.tfvars` lives at repo root; `bootstrap/fleet` now needs it

Tracked: Rework item 15.

**Observation.** `init-gh-apps.sh` writes
`<repo-root>/.gh-apps.auto.tfvars` (gitignored, mode 0600) containing
the three GH App PEMs and IDs. The file was originally intended
solely for `stages/0-fleet`, which receives it through `tf-apply.yaml`
as an explicit `-var-file`. `bootstrap/fleet` now also consumes one
field from it — `fleet_runners_app_pem` — to seed the fleet Key
Vault via `azapi_data_plane_resource.fleet_runners_pem_secret`
before the runner Container App Job is created (ACA validates the
KV reference at PUT time, not at first job execution).

**Trap.** `*.auto.tfvars` only auto-loads from the Terraform module
root being applied. Running `terraform apply` from
`terraform/bootstrap/fleet/` does **not** auto-load the repo-root
file. Without explicit `-var-file`, the required
`fleet_runners_app_pem` variable is unset and apply fails at plan
time with `No value for required variable`.

**Operator contract.** Every `bootstrap/fleet` apply must pass:

```
terraform apply \
  -var-file=$(git rev-parse --show-toplevel)/.gh-apps.auto.tfvars \
  [other flags] tfplan
```

Undeclared-variable warnings from the six Stage-0-only fields in
that file (`fleet_meta_app_id`, `fleet_meta_app_pem`, etc.) are
expected and benign — `terraform` emits warnings, not errors, for
undeclared vars supplied via explicit `-var-file`.

**Action.**

1. Document the `-var-file` requirement in `docs/adoption.md §5.1`
   alongside the existing `allow_public_state_during_bootstrap`
   mention.
2. Update the bootstrap/fleet README (if any) with the same command.
3. Optionally: have `init-gh-apps.sh` emit a second file — e.g.
   `.gh-apps.bootstrap.auto.tfvars` containing **only**
   `fleet_runners_app_pem` + `fleet_runners_app_pem_version` — so
   no undeclared-var warnings fire. Cosmetic; skip unless operator
   noise becomes a support burden.
4. Stage 0's workflow (`tf-apply.yaml`) already passes `-var-file`
   explicitly; no change required there.

**Future.** If additional App PEMs or IDs ever need to cross the
bootstrap/fleet boundary, declare them as `ephemeral = true`
variables and seed as additional `azapi_data_plane_resource` blocks.
Never stage AAD-app secrets through ordinary `azurerm` / `azapi`
resources — they would land in state.

## F6 — Spoke networking is incomplete for hub-and-spoke egress

**Observation.** The mgmt VNets created in `bootstrap/fleet`
(`module.mgmt_network`, invocations of
`Azure/avm-ptn-alz-sub-vending/azure`) peer to the hub but the call
site hard-codes three controls to the no-op default that realistic
hub-and-spoke deployments must override:

1. **`use_remote_gateways` on the spoke→hub peering.** The hub owns
   the VPN/ExpressRoute gateway (or a gateway-equivalent NVA for
   forced tunneling). Without `useRemoteGateways = true` on the
   spoke side and `allowGatewayTransit = true` on the hub side,
   on-prem routes never propagate into the spoke and spoke-to-on-
   prem traffic is silently black-holed. Conversely, setting it
   unconditionally breaks topologies where the hub has no gateway.
   The value must be controllable per-peering.
2. **Route tables on spoke subnets.** Azure's default system routes
   send `0.0.0.0/0` straight to the Internet edge — not to the hub
   firewall. To force egress through the hub's Azure Firewall /
   NVA, each subnet needs a UDR with `0.0.0.0/0 → VirtualAppliance
   → <firewall-ip>`, plus BGP-propagation disabled (or controlled)
   so the default route isn't overridden by a learned route. Today
   no route table is attached to any subnet the call site creates
   (`pe-fleet`, `runners`).
3. **VNet DNS servers.** Private DNS resolution for links like
   `privatelink.vaultcore.azure.net` works via the central PDZ
   linkages today, but any requirement for split-horizon / on-prem
   DNS forwarding (corporate zones, conditional forwarders, Private
   Resolver inbound endpoints) needs
   `properties.dhcpOptions.dnsServers` on the VNet. Today this
   field is unset, meaning the spoke uses Azure-provided DNS
   (168.63.129.16) exclusively. Adopters with a central Private
   DNS Resolver in the hub cannot direct spoke VMs at it.

**Consequence for the walkthrough.** The mgmt VNet peered to
`vnet-test-35ut-swedencentral-001` but is isolated from on-prem
and has no forced-tunnelling path to the hub firewall. Outbound
traffic from the runner pool and future cluster subnets goes
direct to the Internet via the VNet's default edge, bypassing any
hub-centric inspection / egress control. This happens to work for
the walkthrough (GitHub, ACR, Graph are all public endpoints
reachable directly), but it violates the stated hub-and-spoke
intent in PLAN §3.4 and would be a show-stopper for an adopter
with a regulated egress posture.

**Good news — the referenced module already supports all three.**
The gaps are at the `main.network.tf` call site, not in the
module. The sub-vending module is consumed from the Terraform
Registry (`source = "Azure/avm-ptn-alz-sub-vending/azure"`, no
vendored copy in-tree); verified against the `terraform init`-
downloaded copy under `.terraform/modules/mgmt_network/`:

- `variables.virtual-network.tf` declares
  `hub_peering_options_tohub.use_remote_gateways`,
  `hub_peering_options_fromhub.use_remote_gateways`, and
  `dns_servers` (on the `virtual_networks` value schema).
- `variables.route-table.tf` declares `route_table_enabled` +
  `route_tables` as top-level module inputs, and
  `variables.virtual-network.tf` declares a per-subnet
  `route_table = { key_reference | id }` so adopters can either
  have the module create-and-attach, or supply an external
  (hub-owned) route table id.
- `outputs.tf` exposes `route_table_resource_ids` for downstream
  consumers.

**Current call-site state**
(`terraform/bootstrap/fleet/main.network.tf:210-228`):

```hcl
hub_peering_options_tohub = {
  allow_forwarded_traffic      = true
  allow_gateway_transit        = false
  allow_virtual_network_access = true
  use_remote_gateways          = false   # hard-coded
}
hub_peering_options_fromhub = {
  allow_forwarded_traffic      = true
  allow_gateway_transit        = true
  allow_virtual_network_access = true
  use_remote_gateways          = false   # hard-coded
}
# no route_tables { ... }, no route_table_enabled, no subnet.route_table
# no dns_servers on the virtual_networks["mgmt"] value
```

**Scope of the needed rework.**

a. **Peering options.** Replace the hard-coded `false` with
   `each.value.hub_peering.use_remote_gateways` (or similar) so
   the value flows from the env config. Default stays `false` for
   backward compat. `allow_gateway_transit` on `fromhub` should
   stay `true` by default (the hub already permits transit on the
   current default; keep it explicit).

b. **Route tables.** Expose either:
   - Adopter-owned external route tables (preferred for hub-owned
     forced tunneling). Surface `subnet_route_table_ids` as an
     optional per-subnet map on the env; pass
     `subnets.<k>.route_table = { id = ... }` on the module call.
   - Module-created route tables (for adopters running the hub
     firewall from the same repo, which is out of scope for
     `bootstrap/fleet` — hub lives in a separate subscription per
     PLAN §3.4).

   Default `null` per subnet; no route table attached means no
   behaviour change.

c. **VNet-level DNS.** Surface `dns_servers` as an optional
   list-of-string on the env config and pass through to
   `virtual_networks.<key>.dns_servers`. Default `[]` (Azure DNS).

d. **`clusters/_fleet.yaml` schema.** All three fields need schema
   slots. Proposal (per env, under `networking`):

   ```yaml
   networking:
     hub_id: /subscriptions/.../vnet-hub-...
     hub_peering:
       use_remote_gateways: true        # optional, default false
     dns_servers:                       # optional, default Azure DNS
       - 10.0.0.4
     subnet_route_table_ids:            # optional per-subnet override
       pe-fleet: /subscriptions/.../routeTables/rt-hub-...
       runners:  /subscriptions/.../routeTables/rt-hub-...
   ```

   `bootstrap/environment` should expose the same shape for env
   VNets; mechanics are identical (same sub-vending module).

e. **Docs.** `docs/adoption.md` prereq list currently says
   "adopter owns a hub VNet with central PDZs". Add explicit
   call-outs that (i) if the hub has a gateway the adopter wants
   to reach, `use_remote_gateways: true` is required, (ii) if
   egress must traverse the hub firewall, a pre-existing hub route
   table id must be passed via `subnet_route_table_ids`, (iii) if
   a central Private DNS Resolver exists, its inbound endpoint IPs
   go in `dns_servers`.

**Why a single finding.** All three gaps share the same root
cause: the `main.network.tf` call site exposes a reduced surface
sufficient for an "island VNet" (local PEs + central PDZs +
Internet egress) but not for the full hub-and-spoke use case
PLAN §3.4 asserts. Addressing any one in isolation produces a
configuration still broken in the other two directions, so
operators deserve the fix to land together. The sub-vending
module (registry-sourced, not vendored) needs no changes — only
the call site and the `_fleet.yaml` schema.

**Non-goals.**

- Creating the hub VNet, gateway, firewall, or route tables from
  this repo. Those are adopter-owned assets; this repo only
  consumes references to them, the same way it consumes the
  central PDZs.
- Managing NSG rules for forced-tunnelling semantics. NSGs stay
  per-subnet and locally authored; route tables control the path,
  NSGs control the filter.

**Risk.** Exposing `use_remote_gateways` unconditionally as `true`
would break adopters whose hub lacks a gateway. Leaving it as a
nullable with `false` default and surfacing it as an opt-in in
`_fleet.yaml` preserves current behaviour while unblocking gateway
transit for adopters that need it. Same pattern for the other two
fields.

## F7 — Entra directory role assignments plan a forced replacement on every apply

**Observation.** Every `terraform plan` of `bootstrap/fleet` against
an already-applied state reports both
`azuread_directory_role_assignment.stage0_app_admin` and
`.meta_app_admin` as `-/+ (forces replacement)`:

```
~ role_id = "9b895d92-2cd3-44c7-9d02-a6ac2d5ea5c3"
       -> "f6c6f3a8-50d6-4bbb-94b1-ae3174b6428b"   # forces replacement
```

The diff is not a real change. Those two GUIDs are the same role in
two different Graph representations: `9b895d92-…` is the
**roleTemplate** id for "Application Administrator" (the well-known
tenant-agnostic identifier); `f6c6f3a8-…` is this tenant's
**activated directoryRole instance** object id. Verified in the
walkthrough tenant:

```
roleTemplate  ApplicationAdministrator  9b895d92-2cd3-44c7-9d02-a6ac2d5ea5c3
directoryRole  ApplicationAdministrator  f6c6f3a8-50d6-4bbb-94b1-ae3174b6428b
                                          roleTemplateId=9b895d92-…
```

**Evidence.** State inspection after the first apply of
`bootstrap/fleet`:

```
# azuread_directory_role.app_admin
object_id   = "f6c6f3a8-50d6-4bbb-94b1-ae3174b6428b"   # instance
template_id = "9b895d92-2cd3-44c7-9d02-a6ac2d5ea5c3"   # template

# azuread_directory_role_assignment.stage0_app_admin
role_id = "9b895d92-2cd3-44c7-9d02-a6ac2d5ea5c3"       # template!
```

The config writes the assignment's `role_id` from
`azuread_directory_role.app_admin.object_id` (the instance id), so
the create request is correct. But on Read, the provider resolves
the assignment's `roleDefinitionId` from the Graph response and
stores whatever it gets back, which for directory-role assignments
is the template id. Next plan sees state = template, config =
instance, diffs, and because `role_id` is a force-new attribute the
assignment is destroyed and recreated — every apply.

**Impact.**

- Non-idempotent plans: CI's "plan-is-clean" invariant is broken
  on `bootstrap/fleet` forever after the first apply.
- Real resource churn: each apply tears down the live Graph role
  assignment and re-creates it. Between destroy and create the
  target UAMI has no Entra role — a small but real outage window
  for anything actively using the role.
- Confuses drift-detection: operators cannot distinguish "the
  world changed" from "the provider is noisy" at a glance.

**Root cause.** Behaviour of
`hashicorp/azuread.azuread_directory_role_assignment`'s Read
against directory-role assignments. The provider treats `role_id`
as required + force-new, but its Read path normalises to the
template id, which is inconsistent with what the Create path
accepts. Reported upstream in various forms; not fixed in the 3.x
line we pin (`~> 3.8`).

**Options, in order of preference.**

1. **Write `role_id` as the template id directly.** Change the two
   assignments to use
   `role_id = azuread_directory_role.app_admin.template_id`. Create
   still succeeds (Graph accepts either form for directory-role
   assignments) and Read now matches state, so no diff. Single-line
   change per assignment, zero behaviour change, idempotent. **The
   pragmatic fix.**

2. **Move to `azuread_app_role_assignment` against the Graph SP** —
   see F2. F2 already plans to replace the broad "Application
   Administrator" directory role on `fleet-stage0` with the narrower
   Graph app-role `Application.ReadWrite.OwnedBy`. That refactor
   sidesteps F7 entirely because Graph app-role assignments are
   keyed on app-role + resource + principal (stable ids, no template
   / instance dichotomy). For `fleet-meta` the same rework is F1
   (delete the assignment entirely). So F7 becomes moot once F1 and
   F2 land.

3. **`lifecycle { ignore_changes = [role_id] }`.** Suppresses the
   diff but leaves the drift in state and masks real template →
   instance migrations if Microsoft ever changes the canonical
   representation. Not recommended.

**Recommended action.** Apply Option 1 immediately in this repo
(one-line fix on both resources plus a `terraform state rm` +
`terraform import` on the two existing assignments so the stored
`role_id` switches from instance → template without a real destroy/
create cycle against Graph). F1 and F2 remain queued as the
principled long-term fixes — Option 1 unblocks idempotency in the
meantime.

**Scope.** Two lines in
`terraform/bootstrap/fleet/main.identities.tf`. No schema change,
no new variables, no _fleet.yaml touch.

## F8 — `init-gh-apps.sh` should write a curated `.auto.tfvars` into `terraform/bootstrap/fleet/`

Tightly coupled to F5 (explicit `-var-file` workaround). F5 solves
the walkthrough unblock; F8 is the durable ergonomic fix.

**Observation.** `init-gh-apps.sh` writes a single
`<repo-root>/.gh-apps.auto.tfvars` that carries **all** App
metadata (IDs, client IDs, PEMs, webhook secrets for all three
Apps). It was shaped for a future Stage-0 consumer — Stage 0's
`variables.tf` already mentions the full payload in a comment
("not-yet-implemented (PLAN §16.4)"), but no Stage-0 `variable`
blocks exist for those fields today.

Meanwhile `bootstrap/fleet` legitimately consumes exactly one
field from that file — `fleet_runners_app_pem` (plus the optional
`fleet_runners_app_pem_version` version tag) — to seed the Key
Vault secret before the ACA job is created (see the F4-class
change in `main.kv.tf`). None of the other six fields in the
root file are used by any committed Terraform today; they sit
at rest on the adopter's disk waiting for §16.4 to land.

Because `*.auto.tfvars` only auto-loads from the Terraform module
root being applied, operators running `bootstrap/fleet` must
pass `-var-file=<repo-root>/.gh-apps.auto.tfvars` explicitly
(F5), accepting "Value for undeclared variable" warnings for the
six unused fields — a worse ergonomic than necessary given
`bootstrap/fleet` only wants one value out of the file.

**Target design.** Have `init-gh-apps.sh` emit two files, both
gitignored + mode 0600:

1. `<repo-root>/.gh-apps.auto.tfvars` — unchanged, full payload,
   reserved for the §16.4 Stage-0 consumer. Harmless at rest
   until Stage 0 grows the matching `variable` blocks and its
   `tf-apply.yaml` explicit `-var-file`.
2. `terraform/bootstrap/fleet/.gh-apps.auto.tfvars` — new, narrow
   payload containing **only**:
   ```hcl
   fleet_runners_app_pem         = <<EOT
   ...
   EOT
   fleet_runners_app_pem_version = "0"
   ```
   No IDs, no webhook secrets, no other Apps' PEMs.

With file #2 in place, `terraform apply` in `bootstrap/fleet`
auto-loads the PEM, no `-var-file` flag is needed, no "undeclared
variable" warnings fire, and the bootstrap module never sees
material it has no business holding.

**Why not put the narrow file at the bootstrap dir instead of the
root file.** Consolidating to a single `terraform/bootstrap/fleet/
.gh-apps.auto.tfvars` would break the §16.4 Stage-0 rollout when
it lands — Stage 0 runs with `working-directory:
terraform/stages/0-fleet` and auto-loads only from there, so it
would no longer see the full payload. Emitting two curated files
lets each stage's `terraform apply` be idempotent in isolation
as §16.4 fills in.

**Rotation semantics.** Bumping
`fleet_runners_app_pem_version` in
`bootstrap/fleet/.gh-apps.auto.tfvars` drives a re-PUT of the KV
secret without touching the root file. Re-running
`init-gh-apps.sh` (e.g. to rotate the GitHub App) rewrites both
files — the full payload in place, the narrow one with a bumped
version — because it already owns the `.gh-apps.state.json`
lifecycle.

**Action.**

1. Extend `init-gh-apps.sh` (Python-embedded writer around line
   545) to emit the narrow file at
   `terraform/bootstrap/fleet/.gh-apps.auto.tfvars` whenever it
   writes the root file. Content = exactly the two variables
   listed above, extracted from `.gh-apps.state.json`'s
   `fleet_runners.private_key_pem`. Preserve mode 0600.
2. Extend gitignore generation to ignore
   `terraform/bootstrap/fleet/.gh-apps.auto.tfvars` alongside
   the root file.
3. Retire F5: once F8 ships, `bootstrap/fleet` apply needs no
   `-var-file`, and `docs/adoption.md §5.1` can drop the flag
   from its worked command.
4. On rotation, bump `fleet_runners_app_pem_version` inside the
   narrow file. Script writes it as `"0"` initially;
   re-invocations with a changed PEM increment the string
   monotonically (`"1"`, `"2"`, …). Document this in the
   script's header comment.
5. Preserve backward compatibility with existing adopter
   workspaces that pre-date F8 — if the narrow file exists at
   re-run, overwrite it; if the root file already carries the
   PEM (as today), continue writing that too so the §16.4
   Stage-0 rollout is unaffected.

**Non-goals.**

- Removing the root `.gh-apps.auto.tfvars`. Keep it as-is; it's
  the §16.4 Stage-0 input and carrying it costs nothing today.
- Any change to which variables `bootstrap/fleet/variables.tf`
  declares. F8 is purely a file-placement + content-curation fix
  in the init helper; the module contract is unchanged.

**Risk.** Writing a second tfvars file doubles the number of
0600 secrets on disk. Both are gitignored, both live in the
adopter's worktree, and both are under operator control. Net
material exposure is unchanged — the PEM is already on disk in
the root file; F8 just makes a second, narrower copy scoped to
the consumer that needs it.

## F9 — Argo CD topology: every cluster reconciles its own slice; no cross-cluster reach

**Observation.** PLAN and supporting docs refer to a "top-level
app-of-apps" on the mgmt cluster without specifying what it owns,
what it reaches, or what credentials it holds. That framing
invites operators to grant mgmt Argo remote-cluster credentials
and build a centralised fleet reconciler — adding significant
identity/authorization machinery (UAMIs, FICs, AAD groups,
cross-cluster Secret writes, narrow ClusterRoles) for no
operational benefit over a pull-based topology, because all
policy artefacts already live in Git and every cluster already
runs a local Argo.

**Target design — pull-only; mgmt is not special.**

1. **Every cluster runs its own Argo**, installed by Stage 2.
   No structural distinction between mgmt and non-mgmt. Each
   Argo watches exactly one Git path:
   `clusters/<env>/<region>/<name>/`. No Argo anywhere holds
   credentials to any cluster other than itself.

2. **Per-cluster directory layout.** Under each cluster's
   slice, two subtrees with distinct governance:

   ```
   clusters/<env>/<region>/<name>/
     policy/
       appprojects/<team>.yaml           # generator output (F11)
       quotas/<team>.yaml                # generator output
       netpols/<name>.yaml               # generator output
       constraints/<name>.yaml           # generator output
     apps/
       <team>-<app>/…                    # team-authored or Kargo-committed
   ```

   The root `Application` Stage 2 writes on each cluster points
   at `clusters/<env>/<region>/<name>/` (the whole directory) and
   syncs both subtrees. Policy artefacts are applied before or
   alongside workloads on the same cluster, by the same
   reconciler, with no cross-cluster ordering dependency.

3. **Stage 2 bootstraps local Argo via Terraform.** Helm release
   of Argo with workload-identity wiring (KSA annotated with
   the cluster's own UAMI client-id, projected SA-token volume,
   `azure.workload.identity/use: "true"` labels). Stage 2 then
   writes the root `Application` CR and hands off. After Stage 2
   completes, Argo self-manages: the root Application syncs
   Argo's own config (`argocd-cm`, `argocd-rbac-cm`, HA replica
   counts, etc.) from Git. Subsequent Argo upgrades land via
   Git commits, not via re-running Stage 2.

4. **Repo access via the cluster's UAMI.** Argo reads the fleet
   repo authenticated as the cluster's own UAMI (federated to
   its KSA), not via a static GitHub token. The UAMI is granted
   read access on the fleet repo via the existing GitHub-App
   flow (`fleet-meta` posts a repo-scoped installation access
   token into the cluster's KV; ESO projects it into Argo's
   `argocd-repo-creds` secret). No long-lived PAT anywhere.

5. **Kargo is the sole fleet-wide coordinator.** Kargo runs on
   mgmt (its only cluster home — its state model requires a K8s
   API somewhere), watches the shared ACR via its Warehouse,
   and authors Git commits into
   `clusters/<env>/<region>/<name>/apps/`. Remote clusters'
   local Argos pick those commits up on their next sync.
   Cross-cluster coordination happens entirely through Git —
   the fleet repo is the message bus. Kargo has **no** reach to
   any cluster other than mgmt itself.

6. **AppProjects + team policy generated from Git artefacts.**
   See F11. Humans edit `teams/<team>.yaml`; a GH Actions
   generator renders per-cluster policy YAML into each target
   cluster's `policy/` subtree and commits back. Each cluster's
   local Argo picks up its own `policy/` tree on the next sync.
   No central push; no fleet-wide `argocd-rbac-cm` replication.

### Why pull-only, not push

The alternative considered and rejected: a "Tier 1" mgmt Argo
that reconciles policy objects (AppProjects, quotas, NetPols,
Gatekeeper constraints) onto every spoke via workload-identity
federation and a narrow ClusterRole. Superficially attractive —
single UI for fleet policy, automatic fan-out on new clusters —
but examined carefully, every purported advantage already holds
with pull-only:

- **Centralised reconciliation.** Every cluster's local Argo
  reconciles its own policy from Git. Drift detection, desired-
  vs-actual comparison, Argo UI visibility — all present per-
  cluster. Aggregated visibility across clusters is a dashboard
  concern, not a controller concern; you don't need a central
  reconciler to get central visibility.
- **Fan-out on new clusters.** When a new cluster is onboarded,
  Stage 2 installs its local Argo pointing at its own
  `clusters/<...>/` path. The generator has already emitted
  `clusters/<new>/policy/` into the fleet repo (F11). The new
  cluster starts syncing on first boot. No cluster-connection
  Secret on mgmt, no cross-cluster write, no mgmt-must-be-up
  dependency at onboarding time.
- **Policy uniformity.** The generator (F11) is what guarantees
  "edit `teams/foo.yaml` → consistent AppProjects across target
  clusters." A central reconciler would just move bits
  Git-to-cluster that the local Argo is already moving — an
  extra hop, not an extra guarantee.

Push-based centralisation would cost: a fleet-scoped UAMI
(`id-mgmt-argo-fleet-sync`), two FICs (controller + server), two
AAD groups (`fleet-argo-policy-syncers`, `fleet-spoke-registrars`),
an `AKS Cluster User Role` assignment on every spoke for the
fleet UAMI plus an assignment on mgmt for every env UAMI, a
narrow ClusterRole + binding on every spoke, a Role + binding
in mgmt's `argocd` namespace permitting spoke Stage 2 to write
cluster-connection Secrets, and a cross-cluster write step in
every spoke's Stage 2 apply. A significant object graph spanning
three control planes (Entra, each spoke's kube API, mgmt's kube
API) with non-trivial ordering constraints — all in service of
properties Git-based fan-out already provides.

The one real property push-based centralisation offers that
pull-only doesn't: defense-in-depth against compromise of a
spoke's local Argo. A central reconciler is a separate control
loop with a separate identity; it can re-assert policy over a
compromised local Argo's head. This is a legitimate but narrow
property. Local Argo runs on the cluster it syncs into; if it's
compromised, the attacker likely has node-level access to that
cluster anyway and can read secrets, exec into pods, etc.
directly — manipulating AppProjects is an afterthought.
Treating local Argo's integrity as a cluster-level trust
boundary (the same way kube-apiserver's integrity is trusted)
is consistent with how the rest of the system handles cluster
scope. Fleet-wide visibility of per-cluster Argo reconciliation
state (Argo UI federation or a dashboard aggregating Argo
metrics from all clusters) gives operators the observability
they need without requiring a central writer.

### Kargo, revisited

Kargo is the only component in the system that spans clusters,
and it does so by writing to **Git**, not by reaching into
remote cluster APIs. This is the architectural pattern the
whole fleet follows: cross-cluster coordination is always via
Git, never via direct API access. Pull-only Argo reinforces
this pattern. A "Tier 1" mgmt Argo with remote cluster
credentials would have been the one exception — and removing it
leaves the architecture self-consistent: **Git is the only
cross-cluster communication channel, for every component, in
every direction.**

### Consequences

a. **PLAN terminology cleanup.** Any mention of a "top-level
   app-of-apps" on mgmt is replaced with "mgmt cluster runs its
   own local Argo, structurally identical to every other
   cluster's Argo." PLAN §5 (and wherever else the term lands)
   must reflect this.

b. **Stage 2 gains Argo install; no cross-cluster writes.**
   Installing Argo + writing the root Application becomes a
   concrete Stage 2 deliverable on every cluster. Keep it
   small: Helm release with WIF wiring + one root `Application`
   CR apply. No cluster-connection Secret emitted anywhere; no
   AAD group membership writes; no cross-cluster kubeconfig
   handling.

c. **Stage 1 unchanged relative to Argo.** No new UAMIs, no
   new FICs, no fleet-argo-policy-syncers group, no cross-env
   role assignments on mgmt AKS. Stage 1's existing scope
   (per-cluster Azure resources, per-cluster Kargo FIC writes
   on mgmt only) stays as-is.

d. **F2 unchanged.** Every env UAMI still needs
   `Application.ReadWrite.OwnedBy` on the Argo AAD app so
   Stage 2 can write per-cluster FICs for OIDC login to Argo.
   Kargo FIC rotation still runs as `fleet-mgmt` on Stage 1
   mgmt. F2 is independent of F9.

e. **Drift control for AppProjects.** With N clusters each
   applying their own AppProjects from a generator's output,
   two safeguards prevent drift between what "the same team"
   means across clusters:
   - **Generator is single-source.** All per-cluster AppProject
     files for team T come from the same `teams/<team>.yaml`;
     per-cluster substitution is limited to fields that must
     differ (e.g. cluster-scoped `destinations`). Drift is
     structurally blocked at generation time.
   - **CI validator.** Pre-merge check asserts that for every
     team, the generated AppProjects across clusters are
     byte-identical in fields that are supposed to be cluster-
     agnostic (`sourceRepos`, `roles`). Cheap backup if the
     generator logic ever regresses. See F11.

f. **DR posture.** Every cluster's local Argo continues to sync
   from Git regardless of any other cluster's state. Mgmt
   offline affects only Kargo (promotion engine) and mgmt's own
   workloads; nonprod/prod reconciliation is unaffected. This
   is the strongest DR property the topology can offer.

g. **Observability.** Fleet-wide visibility is a separate
   concern, solved by one of: (i) Argo UI's built-in
   multi-cluster mode using read-only `cluster` Secrets on
   mgmt (credentials scoped to `get` on Argo CRDs only — a
   small, bounded read path worth pursuing later if the
   per-cluster UIs become unwieldy), (ii) an external
   dashboard aggregating Argo's Prometheus metrics from all
   clusters, or (iii) `kubectl` contexts across clusters. None
   of these require a write-capable central reconciler.

h. **Non-goals.**
   - Removing Kargo or changing its host cluster. Kargo stays
     on mgmt.
   - OIDC login federation to Argo (unchanged: Stage 0 creates
     the AAD app; Stage 2 writes per-cluster FICs).
   - ESO secret fan-out (unchanged).
   - A read-only mgmt Argo for observability. Potentially
     desirable later; not part of F9's bootstrap scope.
   - Answering "should we drop Kargo in favour of
     runners-author-PRs?" — separate, larger design question.

### Scope of rework

1. **`PLAN.md`** — rewrite any §5 / §10 / §16 passages that
   mention "app-of-apps" or imply mgmt Argo has fleet-wide
   reach. Add a short topology section stating the pull-only
   target design above.
2. **`terraform/stages/2-bootstrap/`** — add the Argo Helm
   install (with WIF wiring) + root-Application write on every
   cluster. The module already exists as a scaffold; this fills
   in its Argo responsibilities.
3. **Repo credential flow.** Wire the fleet-meta GitHub-App
   installation-token flow to land a `repo-creds` Secret in
   each cluster's Argo via ESO. Short finding worth writing
   up; placeholder for now — noted here so implementers don't
   default to a static PAT.
4. **Generator design** — tracked in F11.
5. **`docs/adoption.md`** — new section "Argo topology"
   explaining that every cluster runs its own local Argo, Git
   is the sole cross-cluster channel, and mgmt has no fleet-
   wide reconciliation role.

**Why now.** The prior PLAN language admitted either topology.
Pinning pull-only here prevents mgmt Argo from accreting remote-
cluster credentials as a "natural" extension later, keeps
Stage 2 simple (local-only operations), and preserves the
architectural invariant that Git is the only cross-cluster
channel.

**Risk.** Policy enforcement depends on each cluster's local
Argo doing its job. Accepted — local Argo is treated as a
cluster-level trust boundary, monitored through the Argo UI
(per-cluster today; federated via a future read-only
aggregator if needed). Compromise of a cluster's local Argo is
equivalent to compromise of the cluster itself; defending
against it with a central reconciler would recover nothing and
cost the object graph documented above.

## F11 — AppProject + policy generator: teams schema, CI mechanics, validator

Depends on F9 (establishes AppProjects-in-Git as the chosen
design). F11 specifies the input format, the generator's
execution model, and the guardrails that keep generator output
trustworthy.

**Observation.** F9 decided (Option A): humans edit
`teams/<team>.yaml`; a generator renders per-cluster policy
artefacts into `clusters/<env>/<region>/<name>/policy/` and
commits them back to the fleet repo; mgmt Argo fans them out.
The decision is recorded; the shape of every component is not.
Without a finding, implementers will pick an ad-hoc YAML schema
and an ad-hoc CI wiring, and the resulting system will be
difficult to evolve.

### Input: `teams/<team>.yaml`

Single file per team at the repo root. Minimum viable schema:

```yaml
# teams/payments.yaml
name: payments
display_name: "Payments Platform"
owners:
  - mawhi@example.com
  - teamlead@example.com
github_team: payments-platform              # optional; gates PR approvals

# Which clusters the team deploys to, and quota per cluster.
destinations:
  - cluster_selector: { env: prod }
    namespaces: [payments, payments-edge]
    resource_quota:
      cpu: "16"
      memory: 64Gi
      pods: "200"
      persistent_volume_claims: "50"
  - cluster_selector: { env: nonprod }
    namespaces: [payments, payments-edge, payments-dev]
    resource_quota:
      cpu: "8"
      memory: 32Gi
      pods: "100"
      persistent_volume_claims: "25"

# Which Git repos this team's Argo may sync from.
source_repos:
  - https://github.com/example/payments-gitops
  - https://github.com/example/payments-shared-config

# Which Kubernetes kinds the team may author. Default conservative.
allowed_kinds:
  namespaced:
    - "*/Deployment"
    - "*/StatefulSet"
    - "*/Service"
    - "*/ConfigMap"
    - "*/Ingress"
    - "networking.k8s.io/NetworkPolicy"
    - "external-secrets.io/ExternalSecret"
    - "cert-manager.io/Certificate"
  cluster_scoped: []                        # empty by default

# Sync windows (optional, per-cluster).
sync_windows:
  - cluster_selector: { env: prod }
    kind: allow
    schedule: "0 8 * * MON-FRI"
    duration: 10h
    time_zone: UTC
  # default deny outside windows for prod, inferred if any allow present
```

**Schema stability contract.** Adding fields is always
non-breaking. Removing or renaming a field bumps a
`schemaVersion` at the top of the file (not shown in minimum
schema to keep the typical case clean; added only when needed).
Migrations are generator concerns, not operator concerns.

**Cluster selector semantics.** `cluster_selector` matches
against `cluster.yaml` labels. `{ env: prod }` matches every
cluster whose `_fleet.yaml` env section is `prod`. Conjunctive
AND across keys; no OR or negation (keep selectors boring).
Explicit `cluster: nonprod/swedencentral/aks-nonprod-1` also
supported for surgical one-offs but discouraged.

### Output: `clusters/<env>/<region>/<name>/policy/`

For each team T and each cluster C matching T's destinations,
the generator emits:

```
clusters/<env>/<region>/<name>/policy/
  appprojects/<team>.yaml          # argoproj.io/v1alpha1 AppProject
  quotas/<team>.yaml               # v1 ResourceQuota, per namespace
  syncwindows/<team>.yaml          # if team has sync_windows for this cluster
```

Each file carries a generator header:

```yaml
# GENERATED BY .github/workflows/policy-generator.yaml
# SOURCE: teams/payments.yaml @ <commit-sha>
# DO NOT EDIT — changes will be overwritten on next generator run.
```

The header is how humans (and pre-commit hooks) detect
hand-edits; CI rejects any file with the header whose content
differs from the generator's output for the current team YAML.

### Generator execution model

**Trigger.** `.github/workflows/policy-generator.yaml`, on
push to `main` (or configurable default branch) touching
`teams/**` or `clusters/**/cluster.yaml`. Also a manual
`workflow_dispatch` for operator-driven regenerations after
schema changes.

**Identity.** Runs as `fleet-meta` (the UAMI that already has
repo-write rights via its GitHub App PEM). No new identity.

**Body.** One invocation of `generator/render.py` (say),
living in-repo, Python + `ruamel.yaml`. Reads all of
`teams/*.yaml` and every `clusters/**/cluster.yaml`; renders
the full desired state of `clusters/**/policy/` in a scratch
dir; diffs against the current tree; opens a PR (or commits
directly to `main` if fleet policy permits — operator choice)
with title `chore(policy): regenerate after teams/<team>.yaml`.

**Idempotency.** Running the generator twice without any input
change produces a no-op diff. Tested in CI as part of the
validator.

**Performance.** Full regeneration is O(teams × clusters).
Both are bounded (<100 teams, <20 clusters typical), so
<500ms wall-time. No incremental logic needed.

### Validator: CI guardrails

Three checks, all in `.github/workflows/policy-validate.yaml`,
running on every PR touching `teams/**`, `clusters/**`, or
`generator/**`:

1. **Freshness.** Re-run the generator in a scratch dir;
   assert `diff -r` against the committed `clusters/**/policy/`
   is empty. Catches "operator edited `teams/payments.yaml`
   but forgot to run the generator" and "operator hand-edited
   a generated file".
2. **Cross-cluster consistency.** For each team, compare the
   generated AppProjects across all target clusters. Assert
   byte-identical in fields that must be cluster-agnostic:
   `sourceRepos`, `roles`, `clusterResourceWhitelist`,
   `namespaceResourceWhitelist`. Fields allowed to vary per
   cluster: `destinations`, `syncWindows`. Catches generator
   bugs that introduce accidental per-cluster drift.
3. **Schema validation.** Every `teams/*.yaml` passes a
   JSON-schema check (schema lives in-repo, alongside
   generator). Every generated policy file passes OpenAPI
   validation against the target cluster's Argo/K8s types
   (via `kubeconform` with CRD schemas).

CI fails loudly on any check; generator PRs pass all three by
construction.

### Trust model

The generator is **code**, reviewable in PRs. The generator's
output is **data**, reviewable in PRs. Both pass through the
same PR-approval gate as any other repo change. An operator
compromising the generator can author arbitrary AppProjects,
but so can an operator compromising the fleet repo directly —
the generator does not widen the attack surface, and the
freshness validator catches unauthorized edits to generated
files that bypass the generator.

### Consequences

a. **Stage 2 root Application reference.** Tier 2 Argo's
   root Application on each cluster references AppProjects
   by name in its `project:` field. Those names come from
   `teams/<team>.yaml`. Stage 2 needs no generator awareness
   — it just applies the root Application and trusts Tier 1
   (mgmt Argo, per F9) to have installed the matching
   AppProjects before Tier 2 syncs.

b. **Race on first-ever cluster onboarding.** Tier 2 Argo
   comes up before Tier 1 has synced AppProjects to the new
   cluster. Team Applications on that cluster will fail
   closed with "AppProject <team> not found" until Tier 1
   catches up (sync cycle = minutes). Acceptable: a new
   cluster with no workloads is the expected state during
   onboarding; Tier 1 catches up well before any team
   deployment is attempted.

c. **Team offboarding.** Deleting `teams/<team>.yaml` causes
   the generator to remove all per-cluster AppProject files
   for that team. Mgmt Argo's ApplicationSet then prunes
   the AppProjects from spokes. Team workloads fail closed
   on next sync. Clean and audit-able.

d. **Schema evolution.** The schema is defined in-repo
   alongside the generator. Adding optional fields requires
   only a generator update. Adding required fields (rare,
   avoid) requires a migration pass over existing
   `teams/*.yaml` — committed as a separate PR whose diff is
   the migration itself.

### Non-goals

- Managing Kubernetes-native RBAC (`Role`, `RoleBinding`).
  AppProjects govern Argo's sync authority; Kube RBAC
  governs API server authority. The two serve different
  purposes; conflating them into one "teams" concept
  confuses the audit trail. Kube RBAC stays a Stage 2
  responsibility authored per-cluster; if an AppProject
  grants a team the ability to author `Role` objects in
  their namespace, that's the team's lever.
- Per-environment promotion of `teams/<team>.yaml`. The file
  is global — a team either exists in the fleet or doesn't.
  Per-cluster variation lives in `destinations[].cluster_selector`,
  not in separate per-env team files.
- Cross-fleet team sharing. Every fleet (adopter) owns its
  own `teams/`. A team shared across adopters is two
  separate definitions, kept in sync manually or via a
  shared-config mechanism outside this finding's scope.

### Scope of rework

1. **`generator/render.py`** + in-repo JSON schema for
   `teams/*.yaml`.
2. **`.github/workflows/policy-generator.yaml`** — trigger,
   identity, commit-back mechanics.
3. **`.github/workflows/policy-validate.yaml`** — freshness,
   cross-cluster consistency, schema validation.
4. **`teams/README.md`** — documents the schema and the
   operator workflow ("edit the file, merge the PR, wait
   for the generator bot to regenerate, merge that PR,
   wait for mgmt Argo to sync").
5. **`PLAN.md` §11 or §16** — one paragraph pointing at
   `teams/` as the fleet-operator-facing policy API.
6. **`docs/adoption.md`** — "Onboarding a team" section
   walking through the end-to-end flow.

**Why now.** Deferring the generator design until "after
infra stabilises" risks implementers wiring policy
per-cluster manually for the first few teams, then
discovering the schema they inferred is wrong once scale
demands it. Naming the schema now is cheap and sets the
expectation that `teams/` is the policy API from day one.

**Risk.** Schema lock-in. An early-adopter team's file format
becomes the de-facto contract; schema evolution requires
migration discipline. Mitigation: ship the schema with
`schemaVersion: 1` from the first commit, require all
additions to be optional, accumulate deprecations for a
bundled v2 migration rather than death-by-a-thousand-cuts.
