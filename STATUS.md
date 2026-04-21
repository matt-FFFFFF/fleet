# STATUS

> **What this is.** A one-line-per-sub-item index mirroring
> `PLAN.md`'s section numbers. `PLAN.md` answers "what should be";
> this file answers "what is." Section numbers match `PLAN.md`.
>
> **Discipline.** Routine file-level edits, refactors, and
> in-progress commits do not appear here. Update only when a PLAN
> sub-item's state changes. If in doubt, it doesn't belong.
>
> Legend: `[x]` done · `[~]` in progress / scaffolded but unapplied
> `[!]` **rework required** — code landed for a prior PLAN revision
> and drifts from current PLAN; must be re-aligned before new work
> on the same sub-item · `[ ]` not started · `[-]` deferred.

## §1 Decisions (locked)

- [x] All Phase-1 decisions captured. No open locks.

## §2 Repository layout

- [x] Top-level scaffold (`clusters/`, `terraform/`, `docs/`, `.github/`).
- [x] `init/` throwaway module + `init-fleet.sh`.
- [ ] `platform-gitops/` — Phase 2+.

## §3 Cluster config schema

- [~] §3.1 `clusters/_fleet.yaml` rendered by `init/` — renderer
      rework done (unit 2); end-to-end adoption flow still blocked on
      downstream consumers (`config-loader/load.sh`, `bootstrap/*`,
      stages) catching up. Rewrote `init/templates/_fleet.yaml.tftpl`
      + `init/variables.tf` + `init/render.tf` +
      `.github/fixtures/adopter-test.tfvars` + `init/tests/unit/`:
      dropped `fleet.primary_region`, renamed top-level `environments:`
      → `envs:` with new `envs.mgmt.location`, replaced flat
      `networking.hub.resource_id` with nested
      `networking.hubs.{nonprod,prod}.regions.<region>.resource_id`
      (single hub var fans out; adopters split post-init), removed
      `networking.vnets.mgmt` block (mgmt folded into
      `networking.envs.mgmt.regions.<region>` uniformly), renamed
      `networking_mgmt_address_space` → gone, renamed the three env
      address-space vars to drop `_eastus_` infix, emitted
      `address_space` as a YAML list, added
      `mgmt_environment_for_vnet_peering: prod` on mgmt env-region,
      omitted `create_reverse_peering` (bootstrap default true),
      updated comments to `snet-pe-fleet`, rewrote the pairwise
      overlap validation to 3-way. `init/tests/unit/init.tftest.hcl`
      rewritten: 32 runs pass.
- [x] `clusters/_defaults.yaml` + env `_defaults.yaml`.
- [x] `clusters/_template/cluster.yaml` onboarding scaffold with
      `networking.subnet_slot` required field.
- [x] §3.2 DNS hierarchy; zone FQDN pattern encoded in `_fleet.yaml`.
- [!] §3.3 Derivation rules — **rework required** across
      `config-loader/load.sh` and `modules/fleet-identity/`:
  - `config-loader/load.sh`:
    - L114 reads `.environments[$env].subscription_id` → rename to
      `.envs[$env].subscription_id`.
    - L108-110, L136-138 comments reference removed `networking.vnets.mgmt`
      and "pre-Phase-B" wording → rewrite.
    - L212 `mgmt_vnet_name="vnet-${fleet_name}-mgmt"` (region-less)
      → must become `vnet-<fleet>-mgmt-<region>` (uniform per-region).
    - L214 `mgmt_net_rg="rg-net-mgmt"` (region-less) → must be
      `rg-net-mgmt-<region>`.
    - L271-272 emit `mgmt_vnet_name` / `mgmt_net_resource_group` into
      every cluster's `derived.networking` treating mgmt as singleton
      → must derive from the cluster's own env-region (including when
      `env=mgmt`) via the uniform map.
    - No derivation of `snet-pe-fleet`, `snet-runners`, or
      `snet-pe-env` names; only `snet-aks-api-<cluster>` +
      `snet-aks-nodes-<cluster>` (L218-219). Add the three missing
      subnet name derivations.
    - L150-152 parses `address_space` as scalar; PLAN §3.1 shows it
      as a YAML list — confirm intent and fix parsing accordingly
      (Python `ipaddress.ip_network` at L167 will crash on a list).
  - `modules/fleet-identity/` — **done** (unit 1): rewritten to PLAN
    §3.1/§3.3/§3.4 shape. `envs.mgmt.location` replaces
    `fleet.primary_region` fallback. `networking_central.hubs` is a
    flat `<env>/<region>` map. `networking_derived` is a single
    uniform `envs` map keyed `<env>/<region>` covering every env incl.
    mgmt; `snet_pe_fleet_cidr` + `snet_runners_cidr` present only on
    mgmt entries (fleet zone at HIGH end of /20); `snet_pe_env_cidr`,
    `cluster_slot_capacity`, `node_asg_name`, `nsg_pe_env_name`,
    `route_table_name`, peering names (incl. mgmt-region in
    `-to-mgmt-<region>`), `create_reverse_peering`,
    `mgmt_environment_for_vnet_peering` uniform. Unit tests rewritten
    to cover new shape (8 runs pass).
  - Naming parity sub-item (`docs/naming.md` vs bootstrap HCL locals)
    was already `[ ]`; stays `[ ]` but is now blocked on the above
    rework.
- [!] §3.4 Networking topology — spec rewritten in PLAN (commit
      143d18b) to uniform env-region model. No implementation
      landed yet; all work tracked under the §4 Stage -1 rows and
      the Stage 1 DNS-link rework below.
- [x] Example clusters: `mgmt/eastus/aks-mgmt-01`,
      `nonprod/eastus/aks-nonprod-01` (will need YAML migration to
      new `envs:` shape once schema rework lands).

## §4 Terraform stages

### Stage -1 — `terraform/bootstrap/`

- [!] `bootstrap/fleet/` — **rework required**. Current code targets
      the pre-143d18b schema (single mgmt VNet, `snet-pe-shared`,
      fleet-scope `MGMT_VNET_RESOURCE_ID`). Concrete drift:
  - `main.network.tf` L70-206: single `module "mgmt_network"`
    invocation with `mgmt_vnet_key = "mgmt"` (L77) creates ONE VNet
    with a single address_space (L147-205). Must become one VNet per
    `networking.envs.mgmt.regions.<region>` (iterable).
  - `main.network.tf` L79 `snet_pe_shared_name = "snet-pe-shared"` →
    rename to `snet-pe-fleet`. Propagate rename through L82, L126,
    L154-155, L218-221 (IDs/outputs), and `outputs.tf` L47-50.
  - `main.network.tf` L153-180 subnet map only declares
    `pe-shared` + `runners`; CIDRs are at the LOW end (first two
    /26s). PLAN requires them at the HIGH end (fleet-plane zone =
    second /21 of the /20). Relocate.
  - `main.network.tf` L126 `nsg-pe-shared`, L135 `nsg-runners` →
    must carry `<region>` suffix per PLAN §4 L1136/L1139.
  - `main.network.tf` L36 hub lookup reads
    `local.networking_central.hub_resource_id` (scalar) → consume
    per-env-region hub map.
  - `main.network.tf` L40-43 uses single `mgmt_address_space` → must
    iterate per-region.
  - `main.network.tf` L240-252 authors a single Network Contributor
    role assignment for `fleet-meta` on the one mgmt VNet → must be
    `for_each` over mgmt env-regions.
  - `main.github.tf` L246-252 publishes fleet-scope
    `MGMT_VNET_RESOURCE_ID = local.mgmt_vnet_id` → REMOVE. Replace
    with per-region `MGMT_<REGION>_VNET_RESOURCE_ID` map and add
    `MGMT_<REGION>_PE_FLEET_SUBNET_ID` +
    `MGMT_<REGION>_RUNNERS_SUBNET_ID` publishes (currently absent).
  - `outputs.tf` L42-55 exposes scalar `mgmt_vnet_resource_id`,
    `mgmt_snet_pe_shared_id`, `mgmt_snet_runners_id` → convert all
    three to per-region maps and rename `snet_pe_shared` →
    `snet_pe_fleet`.
  - `main.state.tf` L114, `main.kv.tf` L78, `main.runner.tf` L133-134
    all consume the scalar `snet_pe_shared_id` / `snet_runners_id`
    → must pick the correct mgmt region for each resource (state SA
    region, fleet KV region, runner pool region).
  - Stale comments in `main.tf` L7-31, `main.state.tf` L98-99,
    `main.kv.tf` L64-65, `main.runner.tf` L126-127 reference
    "snet-pe-shared" / "mgmt VNet" singular / `MGMT_VNET_RESOURCE_ID`
    → update.
  - **Scope expansion**: `bootstrap/fleet` must NO LONGER author
    cluster-workload subnets on the mgmt VNet. It authors the VNet
    shell + fleet-plane subnets only; cluster-workload subnets
    become `bootstrap/environment`'s responsibility (see below).
  - [ ] GH Apps (`fleet-meta`, `stage0-publisher`, `fleet-runners`) —
        documented as TODO in `main.github.tf`; manifest-flow helper
        not written. Not affected by drift.
- [!] `bootstrap/environment/` — **rework required**. Concrete drift:
  - `main.tf` L30-32 reads `local.fleet_doc.environments[var.env]` →
    `envs[var.env]`.
  - `main.tf` L36 defaults location from `local.fleet.primary_region`
    → must default from `local.envs.mgmt.location` (for env=mgmt) or
    from the env-region map for other envs.
  - `variables.tf` L15-29 validation yamldecodes `.environments` →
    `.envs`.
  - `variables.tf` L54-70 `variable "mgmt_vnet_resource_id"` (scalar
    ARM id, docstring referencing `MGMT_VNET_RESOURCE_ID`) → REMOVE
    entirely. Replace with a per-region map input (e.g.
    `mgmt_vnet_resource_ids = { <region> = <id> }`) sourced from
    `MGMT_<REGION>_VNET_RESOURCE_ID` GH env vars.
  - `main.network.tf` has NO `var.env == "mgmt"` branch. Must add:
    when `env == "mgmt"`, skip VNet creation (VNets pre-exist from
    `bootstrap/fleet`) and carve cluster-workload subnets as
    `azapi_resource` children on the referenced VNet id using the
    Network Contributor grant pre-placed by `bootstrap/fleet`.
  - `main.network.tf` L166-174 `subnets = { pe-env = {...} }` is
    missing api pool, nodes pool, and route table. PLAN §4.1 L1326-1334
    requires `snet-aks-api` (api pool `/24`), `snet-aks-nodes`
    (nodes pool `/21`), and `rt-aks-<env>-<region>` with `0.0.0.0/0`
    → `networking.egress_next_hop_ip` UDR, associated with BOTH the
    api and nodes subnets. Currently the file's comment L17-19 says
    these are "NOT created here" — directly contradicts PLAN.
  - `main.network.tf` L177-178 reads scalar
    `local.networking_central.hub_resource_id` → per-env-region hub
    map.
  - `main.peering.tf` L27 iterates `local.vnet_keys_by_region`
    unconditionally → must guard `var.env != "mgmt"` (mgmt doesn't
    peer to itself).
  - `main.peering.tf` L32 `remote_virtual_network_id = var.mgmt_vnet_resource_id`
    (scalar) → pick per-region mgmt VNet id via
    `mgmt_environment_for_vnet_peering` + region lookup.
  - `main.peering.tf` L41-46 hardcodes `create_reverse_peering = true`
    and unconditionally populates reverse-peering fields → must read
    `networking.envs.<env>.regions.<region>.create_reverse_peering`
    (default true) and null reverse fields when false.
  - `main.network.tf` L227-250 `node_asg` for env=mgmt resolves
    `local.env_rg_id` to `rg-net-mgmt` (wrong, must be
    `rg-net-mgmt-<region>`).
  - `main.github.tf` L130-168 publishes per-region
    `<ENV>_<REGION>_VNET_RESOURCE_ID` +
    `<ENV>_<REGION>_NODE_ASG_RESOURCE_ID` correctly in shape, but
    for env=mgmt the underlying map sources from a module that
    won't run → path is structurally broken until the env=mgmt
    branch above lands.
  - `outputs.tf` L31-42 per-region outputs rely on module outputs;
    same structural dependency as above.
- [~] `bootstrap/team/` — refactored onto the vendored module;
      awaits `team-bootstrap.yaml` CI flow. Not affected by networking
      drift.

### Stage 0 — `terraform/stages/0-fleet`

- [~] Scaffolded; **not yet applied**:
  - [x] ACR (Premium, zone-redundant, admin disabled).
  - [x] Fleet Key Vault consumed (owned by `bootstrap/fleet`); Stage 0
        holds `Key Vault Secrets Officer` for rotations.
  - [x] Argo AAD application + service principal.
  - [x] Argo RP `client_secret` rotation (60d cadence).
  - [x] Kargo AAD application + service principal.
  - [x] Kargo mgmt UAMI (`uami-kargo-mgmt`) + `AcrPull` on fleet ACR.
  - [x] Redirect URIs derived from cluster inventory.
  - [x] Outputs exported per PLAN §4 Stage 0 table.
  - [!] Fleet ACR private endpoint rewire to derived subnet — was
        tracked as `snet-pe-shared`; rename to `snet-pe-fleet` per
        PLAN and source from per-region mgmt subnet map.

### Stage 1 — `terraform/stages/1-cluster`

- [!] Networking slice — **rework required**. Current code consumes a
      fleet-scope `var.mgmt_vnet_resource_id` / `MGMT_VNET_RESOURCE_ID`.
      Concrete drift:
  - `variables.tf` L25-27 header comment documents fleet-scope
    `MGMT_VNET_RESOURCE_ID` pipeline → rewrite.
  - `variables.tf` L62-73 `variable "mgmt_vnet_resource_id"` (scalar)
    → replace with `mgmt_region_vnet_resource_id` (or similar
    per-region resolution) sourced from
    `MGMT_<REGION>_VNET_RESOURCE_ID`.
  - `main.tf` L17, L31-33, L68, L90-93 all reference the fleet-scope
    mgmt variable in comments, locals, and preconditions → update.
  - `main.aks.tf` L18, L80, L91-94: `linked_vnet_ids` map uses
    fleet-scope mgmt id. Must use mgmt env-region VNet id for the
    cluster's region. Missing: mgmt-cluster collapse — when
    `local.cluster.env == "mgmt"` the env and mgmt ids are the same
    VNet and the link list must deduplicate.
  - `providers.tf` L17-22 header comment documents
    `MGMT_VNET_RESOURCE_ID` publishing by `bootstrap/fleet` → rewrite
    (ownership moves to `bootstrap/environment` per PLAN §4 Stage 1
    L859-866).
  - **Missing (not drifted, gap)**: Stage 1 does NOT author a route
    table association on either the api or nodes subnet. PLAN §3.4
    now requires `routeTableId` set on BOTH subnets from the
    `bootstrap/environment`-owned `rt-aks-<env>-<region>`. No
    `var.route_table_resource_id` input exists; neither subnet's
    `properties.routeTable.id` is set in `main.network.tf`. This
    blocks live apply (UDR egress).
  - [ ] Identity/RBAC follow-up: cluster KV, UAMIs (external-dns,
        ESO, per-team), role assignments (AcrPull on kubelet, RBAC
        Cluster Admin for `fleet-<env>` + AAD groups, RBAC Reader
        for Kargo mgmt, Private DNS Zone Contributor, Monitoring
        Metrics Publisher), managed Prometheus DCR/DCRA + rules,
        Kargo mgmt OIDC secret rotation. Not affected by drift.
- [x] Pod CIDR / service CIDR hard-coded fleet-wide constants
      (`100.64.0.0/16` / `100.127.0.0/16`) in `modules/aks-cluster`.
- [x] `validate.yaml` subnet_slot PR-check (presence, type, range,
      uniqueness, immutability).
- [ ] `tf-apply.yaml` workflow (PLAN §10).

### Stage 2 — `terraform/stages/2-bootstrap`

- [ ] Not started (Phase 2).
- [ ] `terraform/modules/argocd-bootstrap` — not written.

## §5 ArgoCD + Kargo bootstrap sequence

- [ ] Phase 2.

## §6 Platform promotion model (Kargo)

- [ ] Phase 4–5.

## §7 Team tenancy

- [ ] Phase 6.

## §8 Secrets & identity

- [~] Design locked; identity seeds scaffolded in Stage -1. ESO + KV
      wiring pending Stage 2.

## §9 RBAC

- [x] Design locked; per-env group bindings expressed as empty `[]`
      with `TODO` comments in rendered `_fleet.yaml`.
      `bootstrap/fleet` preconditions guard fleet-scope fields;
      `bootstrap/environment` does not yet guard every TODO uniformly.

## §10 CI/CD

- [ ] `validate.yaml`, `tf-plan.yaml`, `tf-apply.yaml`,
      `env-bootstrap.yaml`, `team-bootstrap.yaml` — not yet written.
- [x] `.github/workflows/template-selftest.yaml` (template-side only).
- [x] `.github/workflows/status-check.yaml` (template-side only).
- [x] `.github/workflows/tflint.yaml` + `.tflint.hcl` recursive
      enforcement.
- [x] `terraform test` unit suites (template-side): `init/tests/unit/`
      and `modules/fleet-identity/tests/unit/`. **Tests will need
      updating** in lockstep with §3.1/§3.3 schema rework.

## §11 Operator UX

- [!] `docs/adoption.md` — rework required: L49 `primary_region`
      default, L61 single-region mgmt assumption, L234
      `networking.hub.resource_id` scalar, L239 mgmt VNet owned by
      `bootstrap/fleet` + `networking.vnets.mgmt.address_space`,
      L240 `snet-pe-shared` → `snet-pe-fleet`.
- [!] `docs/networking.md` — rework required: L29 mgmt row (single
      VNet, owned by `bootstrap/fleet`), L35/L39 `networking.hub`
      scalar in Mermaid, L38-41 + L61-64 Mermaid diagrams assume
      single mgmt VNet, L82-84 `bootstrap/fleet` owns mgmt VNet,
      L121 `snet-pe-shared` token in CIDR diagram, L215-231 capacity
      tables don't reflect mgmt-has-fleet-plane-zone split,
      L290-295 peering ownership table, L306
      `publish MGMT_VNET_RESOURCE_ID` (stale var), L313 missing
      `MGMT_<REGION>_{PE_FLEET_SUBNET_ID,RUNNERS_SUBNET_ID}`,
      L336-337 DNS-link pair wording, L367-372 repo variables table.
      Route-table/UDR section missing entirely.
- [!] `docs/onboarding-cluster.md` — rework required: L126-131 +
      L162-163 reference fleet-scope `MGMT_VNET_RESOURCE_ID` and
      always-two-link phrasing (mgmt-cluster collapse missing).
- [!] `docs/naming.md` — rework required: L21 `fleet.primary_region`,
      L22 `environments.<env>` → `envs.<env>`, L27
      `networking.vnets.mgmt`, L72 `vnet-<fleet>-mgmt` (region-less),
      L74 `rg-net-mgmt` (region-less), L76-77 `snet-pe-shared` +
      `networking.vnets.mgmt.address_space`, L85 `nsg-pe-shared`,
      missing `snet-pe-env` on mgmt.
- [ ] `onboarding-team.md`, `upgrades.md`, `promotion.md`.

## §12 Risks and mitigations

- Reference-only.

## §13 Phased implementation

- [~] **Phase 1 (Skeleton)** — in progress:
  - [x] Repo scaffold per §2.
  - [!] `_fleet.yaml` (generated) + `_defaults.yaml` — rendering
        driven by `init/` which drifts from PLAN; see §3.1 above.
  - [!] `bootstrap/fleet` code; not applied; **rework required** per
        §4 Stage -1 above.
  - [!] `bootstrap/environment` code; not applied; **rework required**
        per §4 Stage -1 above.
  - [!] `stages/0-fleet` body; not applied; **rework required** on
        ACR PE subnet name + source.
  - [!] `stages/1-cluster` — **rework required** on mgmt VNet
        resolution (per-region) + DNS-link collapse for mgmt +
        missing route table association.
  - [ ] `config-loader/load.sh` naming-derivation parity — blocked
        on §3.3 rework.
  - [ ] CI workflows (`validate`, `tf-plan`, `tf-apply`,
        `env-bootstrap`).
  - [ ] **Exit criterion** (both clusters provision and pull from
        fleet ACR) — not met; blocked on schema rework + route table.
- [ ] Phase 2 (ArgoCD bootstrap).
- [ ] Phase 3 (Platform services pre-Kargo).
- [ ] Phase 4 (Kargo install).
- [ ] Phase 5 (Platform promotion rollout).
- [ ] Phase 6 (Team tenancy + promotion).
- [ ] Phase 7 (Hardening).

## §14 Resolved Phase-1 configuration

- Reference-only.

## §15 Remaining open items (deferred)

- Reference-only.

## §16 Template-repo adoption model

- [!] §16.1 Single source of truth (`clusters/_fleet.yaml` generated)
      — rendered by `init/` which drifts; rework lands with §3.1.
- [!] §16.2 Bootstrap TF reads yaml — rework required; both stacks
      still read `environments.<env>` / `networking.hub` /
      `networking.vnets.mgmt`.
- [x] §16.3 `init-fleet.sh` wrapper over `init/` TF module.
- [x] §16.4 `init-gh-apps.sh` — manifest flow for `fleet-meta` /
      `stage0-publisher` / `fleet-runners` Apps; writes
      `./.gh-apps.state.json` + `./.gh-apps.auto.tfvars`; patches
      `_fleet.yaml` with runner IDs; self-deletes. Stage 0 wiring of
      the tfvars overlay remains TODO.
- [x] §16.5 GitHub template mechanics; `import` block for fleet repo.
- [!] §16.6 `docs/naming.md` — rework required; see §11.
  - [ ] CI diff between `load.sh` and bootstrap HCL locals — deferred.
- [x] §16.7 Safety rails (banner, dirty-tree refusal, TF validation).
- [x] §16.8 Template self-test workflow. Selftest fixture will need
      updating to new schema in lockstep.
- [!] §16.9 File additions/modifications — **rework required** to
      land uniform env-region networking schema (`envs` rename,
      `networking.hubs` map, `envs.mgmt.location`, per-env-region
      `create_reverse_peering`, `mgmt_environment_for_vnet_peering`,
      `snet-pe-fleet` rename, mgmt-as-env-region) in:
      `init/templates/_fleet.yaml.tftpl`, `init/variables.tf`,
      `init/render.tf`, `config-loader/load.sh`,
      `modules/fleet-identity/`, `bootstrap/fleet/`,
      `bootstrap/environment/`, `stages/1-cluster/`, and docs.
- [x] §16.10.1–9 Execution order complete.
  - [-] §16.10.10 CI naming-diff — deferred to Phase 2 CI work.

---

## Outside-PLAN scaffolding

- [x] `.fleet-initialized` marker contract.
- [x] `.github/fixtures/adopter-test.tfvars` selftest input —
      will need regenerating post-schema-rework.
- [x] `AGENTS.md` — agent onboarding preamble.
- [x] `terraform/modules/github-repo/` vendored fork. See
      `VENDORING.md` for upstream diff.
- [x] `terraform/modules/cicd-runners/` vendored fork. See
      `VENDORING.md` for upstream diff.
- [~] `terraform/modules/fleet-identity/` pure-function derivation
      module — unit 1 of the rework landed: schema contract now
      matches PLAN §3.1/§3.3/§3.4 (uniform per-(env,region) map,
      mgmt-as-env-region, HIGH-end fleet zone, `snet_pe_fleet_cidr`
      rename, peering-name mgmt-region suffix, toggle passthroughs).
      Unit tests rewritten (8 pass). Consumers in `bootstrap/fleet`,
      `bootstrap/environment`, `stages/1-cluster` still reference the
      old output shape — those units (4-6 in the rework program) will
      rewire them.
- [x] `allow_public_state_during_bootstrap` first-apply-only variable
      on `bootstrap/fleet` (tfstate SA public toggle).
- [x] Terraform floor `~> 1.14` across all first-party modules + CI;
      exact version pinned in `.terraform-version`.
- [x] `main`-branch protection via vendored `modules/ruleset`
      (Kargo-bot bypass deferred per §10 / §15).

## Rework program (PLAN §3.1 / §3.3 / §3.4 / §4 realignment)

Ordered units of work to clear every `[!]` above. Each unit is
self-contained enough to land in its own PR.

1. **Schema base — `modules/fleet-identity/`**. ✅ **Done.** Rewrote
   parsed-yaml contract for `envs.<env>`, `networking.hubs`, uniform
   per-(env,region) map incl. mgmt, HIGH-end fleet zone, renamed
   `snet_pe_shared_cidr` → `snet_pe_fleet_cidr`, peering names
   include mgmt-region, passthroughs for `create_reverse_peering` +
   `mgmt_environment_for_vnet_peering`. Unit tests rewritten (8
   pass). `init/tests/unit/` rewritten alongside the renderer in
   unit 2.
2. **Renderer — `init/`**. ✅ **Done.** Rewrote
   `init/templates/_fleet.yaml.tftpl`, `init/variables.tf`,
   `init/render.tf`, `.github/fixtures/adopter-test.tfvars`, and
   `init/tests/unit/init.tftest.hcl` to emit the new schema. Kept
   per-env address-space scalars (hard-coded `primary_region`); open
   map over `(env, region)` deferred — adopters add additional regions
   post-init by editing `_fleet.yaml`. 32 tests pass.
3. **Config loader — `terraform/config-loader/load.sh`**. Rename
   yaml reads, fix mgmt naming (per-region), add `snet-pe-fleet` /
   `snet-pe-env` / `snet-runners` derivations, fix
   address_space scalar-vs-list handling.
4. **`bootstrap/fleet` network** — per-region mgmt VNet shells,
   fleet-plane subnets at HIGH end, rename `snet-pe-shared` →
   `snet-pe-fleet`, per-region NSGs, per-region Network Contributor
   grants, drop fleet-scope `MGMT_VNET_RESOURCE_ID`, publish
   `MGMT_<REGION>_{VNET_RESOURCE_ID,PE_FLEET_SUBNET_ID,RUNNERS_SUBNET_ID}`.
   Update `outputs.tf` to per-region maps. Update `main.state.tf`,
   `main.kv.tf`, `main.runner.tf` to pick the correct mgmt region
   per resource.
5. **`bootstrap/environment` network** — add env=mgmt branch that
   references pre-existing mgmt VNet via per-region input and
   carves subnets as `azapi_resource` children; add api pool +
   nodes pool subnets and `rt-aks-<env>-<region>` route table with
   `0.0.0.0/0` UDR associated to both subnets; rewrite
   `main.peering.tf` to guard `var.env != "mgmt"` and honour
   per-env-region `create_reverse_peering`; replace scalar
   `var.mgmt_vnet_resource_id` with per-region map; fix `main.tf`
   `envs.<env>` rename and location default.
6. **Stage 1 rework** — replace `var.mgmt_vnet_resource_id` with
   per-region resolution; add mgmt-cluster DNS-link collapse; add
   `var.route_table_resource_id` input and set `routeTableId` on
   both api and nodes subnets.
7. **Stage 0 ACR PE** — rewire to derived `snet-pe-fleet` in the
   correct mgmt region.
8. **Docs** — rewrite `docs/naming.md`, `docs/networking.md`,
   `docs/adoption.md`, `docs/onboarding-cluster.md` per §11
   drift list.
9. **Identity/RBAC Stage 1 follow-up** (pre-existing `[ ]`; gated
   by unit 6).
10. **Live apply** of `bootstrap/fleet` + `stages/0-fleet` against a
    real tenant (pre-existing `[ ]`; gated by units 1-7).
11. **CI workflows** (`validate`, `tf-plan`, `tf-apply`,
    `env-bootstrap`) — unblocks Phase 1 exit criterion.
12. **Naming-diff CI** between `load.sh` and bootstrap HCL locals
    (deferred, but should land before Phase 2).
