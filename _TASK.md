# _TASK.md — networking topology implementation

> **Scope.** Encode PLAN §3.4 (networking topology) into code. This
> file is the working checklist for the `feat/networking-topology`
> branch. **Delete this file in the commit that closes the last box.**
> PLAN.md / STATUS.md / `docs/` are the durable source of truth.
>
> **Ordering is prescriptive** — upstream items unblock downstream
> items. Work top-to-bottom; ship each phase as a reviewable commit
> (or small PR-sized group). Every commit flips the matching
> STATUS.md line in the same commit.

---

## Pre-flight (one-time)

- [x] **Pin AVM module versions.** Resolved 2026-04-20 via registry
      API. Use these pins verbatim in every `source` / `version` pair.
  - sub-vending pin: **`~> 0.2`** (latest `0.2.0`, 2026-03-26).
    `terraform.tf` declares `terraform ~> 1.10` (compatible with our
    `~> 1.11` floor) and `required_providers` = { `azapi ~> 2.5`,
    `modtm ~> 0.3`, `random ~> 3.5` }. Every callsite must declare
    all three in its own `required_providers`.
  - peering pin: **`~> 0.17`** (latest `0.17.1`). Source is
    `Azure/avm-res-network-virtualnetwork/azurerm//modules/peering`
    (**note: `azurerm`, not `azure`** — PLAN §3.4 references were
    corrected in this same task). Requires `terraform >= 1.9`,
    `azapi ~> 2.0`. `create_reverse_peering = true` +
    `reverse_name` confirmed in the submodule README.
- [x] **Verify AKS agent-pool ASG support.** Resolved 2026-04-20.
  - [x] Supported → Stage 1 passes ASG id on the agent pool directly.
        In `Azure/avm-res-containerservice-managedcluster/azurerm`
        `v0.5.3` (latest; pin as `~> 0.5`), the `agent_pools` map
        exposes `network_profile.application_security_groups` as
        `optional(list(string))` (see
        `variables.tf` L451). No NSG fallback required; the
        "Fallback" paragraph in PLAN §3.4 remains as reference only
        (keep it in case of future module regression).
  - [ ] Not supported → (not triggered)

---

## Phase A — Derivation layer (pure, no cloud)

- [x] Extend `terraform/modules/fleet-identity/` to emit (pure locals;
      no provider calls):
  - [x] Mgmt VNet name/RG, `snet-pe-shared` / `snet-runners` CIDRs
        (first and second `/26` of mgmt `address_space`).
  - [x] Env VNet name/RG per `<env>-<region>`, `snet-pe-env` CIDR (first
        `/26`).
  - [ ] Per-cluster `/24` from `networking.subnet_slot` — **deliberately
        not emitted from this module** (no cluster input). Lives in
        `config-loader/load.sh` + Stage 1 HCL; parity documented in
        `docs/naming.md`.
  - [ ] `snet-aks-api-<cluster>` / `snet-aks-nodes-<cluster>` CIDRs
        — same reason; cluster-scope.
  - [x] Peering names `peer-<env>-<region>-to-mgmt` /
        `peer-mgmt-to-<env>-<region>`.
  - [x] ASG name `asg-nodes-<env>-<region>`.
  - [x] VNet-capacity integer per env-region (for PR-check max slot)
        — `cluster_slot_capacity` on both `mgmt` and `envs["<e>/<r>"]`.
  - Also emitted: `nsg_pe_name` (`nsg-pe-env-<env>-<region>`) since
    Phase D needs it too.
- [x] Add fixture cases + assertions to
      `terraform/modules/fleet-identity/tests/unit/fleet_identity.tftest.hcl`
      covering: absent-networking → nulls; canonical `/20` topology
      (names + two reserved /26s + 15-slot capacity + peering names +
      ASG name); multi-env + multi-region flatten (3 keys); wider `/19`
      → 31 slots. **8 run blocks, all pass.**
- [x] Extend `terraform/config-loader/load.sh` with the same
      networking derivations so Stage 1 sees `snet-aks-api-*` /
      `snet-aks-nodes-*` CIDRs, the env VNet name, the peering
      names, and `node_asg_name` in its merged tfvars.json. Cluster-
      scope CIDR math uses inline python3 (`ipaddress`). `subnet_slot`
      is required (fails fast if missing or non-integer) and
      slot-range validated against env VNet capacity. Smoke-tested
      slots 0/7/14/15 at `/20`: slot 0→10.20.1.0/24, slot 14→10.20.15.0/24,
      slot 15 rejected. Emitted under `.derived.networking` on the
      merged tfvars.json.
- [x] Update `docs/naming.md` with the new rows (mirrors PLAN §3.3
      derivation table). Added implementers list entry for
      `modules/fleet-identity/`; added inputs note for the two
      address_space fields + cluster `subnet_slot`; added
      "Cluster slot capacity" subsection with the `/20`→15 /
      `/19`→31 math.

## Phase B — Schema flip (`_fleet.yaml` + `cluster.yaml`)

- [x] `init/templates/_fleet.yaml.tftpl`:
  - Added `networking.hub.resource_id`,
    `networking.private_dns_zones.{blob,vaultcore,azurecr,grafana}`,
    `networking.vnets.mgmt.{location,address_space}`,
    `networking.envs.<env>.regions.<primary_region>.address_space`
    (one entry per env under primary_region; second-region line left
    as a commented hint under nonprod).
  - Removed `networking.grafana_pe_subnet_id` + `grafana_pe_linked_vnet_ids`
    from all three per-env blocks; removed
    `networking.{tfstate,runner,fleet_kv}` fleet-scope sub-blocks.
    Central DNS zone refs now consolidate under
    `networking.private_dns_zones`.
- [x] `init/variables.tf`: added 9 typed vars (`networking_hub_resource_id`,
      four PDZ ids, four address_space values) with `validation {}`
      covering: ARM resource id shape, exact PDZ zone name, CIDR
      syntax, /20 minimum, RFC1918 containment, pairwise distinct
      network addresses across the four repo-owned VNets. Overlap
      rule uses normalized `cidrsubnet(_, 0, 0)` comparison guarded
      with `alltrue(can(...))` so it defers to per-field CIDR syntax
      checks when any input is malformed. Narrow-prefix + overlap
      rules also `can(...)`-guard to avoid cross-rule crashes.
- [x] `init/inputs.auto.tfvars`: added `__PROMPT__` sentinels for the
      9 new fields with inline prompt hints grouped under a
      "Networking (PLAN §3.4)" header.
- [x] `init/render.tf`: extended the rendering `ctx` map with all 9
      new values so `templatefile()` interpolates them.
- [ ] `init-fleet.sh`: no code change needed — prompt flow is driven
      by `__PROMPT__` sentinels in `inputs.auto.tfvars`. Verification
      deferred to Phase H (selftest re-run).
- [x] `clusters/_template/cluster.yaml`: added required
      `networking.subnet_slot: 0` with an inline comment pointing at
      PLAN §3.4 (range, immutability, uniqueness, derivation); removed
      `networking.vnet_id`, `subnet_name`, `dns_linked_vnet_ids`.
- [x] `clusters/{mgmt,nonprod}/eastus/aks-{mgmt,nonprod}-01/cluster.yaml`:
      replaced BYO networking blocks with `networking.subnet_slot: 0`
      (each in a different env VNet so sharing slot 0 is valid).
- [ ] JSON-schema / `validate.yaml` linter updates — `validate.yaml`
      does not yet exist (STATUS §10 tracks it); deferred to Phase F
      (which writes the PR-check in scope) or to when `validate.yaml`
      lands.
- [x] `.github/fixtures/adopter-test.tfvars`: added concrete values
      for all 9 new networking vars (hub + PDZs under synthetic sub
      `6666...`; address spaces `10.50/20`, `10.60/20`, `10.70/20`,
      `10.80/20`).
- [x] `init/tests/unit/init.tftest.hcl`: extended file-level
      `variables{}` defaults with the 9 new vars; added
      `render_networking_shape` run asserting the rendered yaml's
      `networking.hub.resource_id`, `private_dns_zones.*`,
      `vnets.mgmt.{location,address_space}`,
      `envs.<env>.regions.eastus.address_space`, and absence of the
      legacy BYO subnet fields; added 7 `expect_failures` runs
      covering bad hub id, wrong PDZ zone name for two zones, bad
      CIDR, too-narrow CIDR, non-RFC1918, and distinctness violation.
      **30/30 tests pass.**

## Phase C — `bootstrap/fleet` mgmt VNet

- [x] `terraform/bootstrap/fleet/main.network.tf` (new):
  - `module "mgmt_network"` → sub-vending `~> 0.2`,
    `subscription_alias_enabled = false` + explicit `subscription_id`
    (we run against the already-bootstrapped shared sub), N=1,
    `hub_peering_enabled = true` (direction = both) pointed at
    `networking.hub.resource_id`,
    `enable_telemetry = false`.
  - Two NSGs (`nsg-pe-shared` + `nsg-runners`) authored via the
    module's `network_security_groups` + subnet `key_reference` input;
    `security_rules = {}` — PE subnets need no explicit ingress,
    runner subnet egress-only via hub UDR.
  - RG `rg-net-mgmt` created via module (`resource_group_creation_enabled = true`).
  - Runner subnet carries ACA delegation (`Microsoft.App/environments`).
  - Subnet resource ids synthesised as `<vnet-id>/subnets/<name>`
    (the sub-vending module does not emit subnet ids directly).
  - `azapi_resource` role assignment: **Network Contributor** on the
    mgmt VNet id → `fleet-meta` UAMI principal, so
    `bootstrap/environment` can author the reverse half of every
    mgmt↔env peering via `create_reverse_peering = true`.
  - Early `terraform_data.network_preconditions` rejects null / `<...>`
    / wrong-suffix values for hub resource id + the three central
    PDZ ids (blob, vaultcore, azurecr) + mgmt address_space, with
    yaml-anchored error messages.
- [x] Rewire existing PE/ACA consumers to derived subnet outputs:
  - `main.state.tf` — tfstate SA PE parent subnet → `local.snet_pe_shared_id`;
    DNS zone group now unconditional, targeting `networking_central.pdz_blob`.
  - `main.kv.tf` — fleet KV PE parent subnet → `local.snet_pe_shared_id`;
    DNS zone group unconditional → `networking_central.pdz_vaultcore`;
    dropped the legacy `fleet_kv_pe_subnet_id` precondition (now
    handled centrally in `main.network.tf`).
  - `main.runner.tf` — `container_app_subnet_id = local.snet_runners_id`,
    `container_registry_private_endpoint_subnet_id = local.snet_pe_shared_id`,
    `container_registry_dns_zone_id = networking_central.pdz_azurecr`;
    runner preconditions trimmed to GH-App identifiers only
    (networking prechecks live in `main.network.tf`).
  - Fleet ACR PE: deferred — Stage 0 owns the ACR, so the rewire
    lands when Stage 0 is next touched. Captured as TODO in STATUS §4
    Stage 0.
- [x] `providers.tf`: added `modtm ~> 0.3` (sub-vending dependency)
      with an empty `provider "modtm" {}` block; `azapi ~> 2.9` and
      `random ~> 3.8` already satisfy sub-vending's `~> 2.5` / `~> 3.5`.
- [x] `outputs.tf`: added `mgmt_vnet_resource_id`,
      `mgmt_snet_pe_shared_id`, `mgmt_snet_runners_id`.
- [x] `main.github.tf`: added `MGMT_VNET_RESOURCE_ID = local.mgmt_vnet_id`
      to `meta_env_vars` — published as a repo-environment variable on
      the `fleet-meta` GitHub Environment, consumed by
      `bootstrap/environment` (reverse peering) and stages/1-cluster
      (cluster DNS zone VNet links). **Resolves the first open question
      in favour of option (b)** (publish directly from `bootstrap/fleet`);
      Stage 0 passthrough not needed — the variable is written by the
      stage that creates the VNet, which is simpler than routing it
      through Stage 0. PLAN §4 Stage 0 outputs table unchanged.
- [x] `modules/fleet-identity`: replaced legacy `networking` output
      (BYO per-service subnet ids, all null after Phase B) with
      `networking_central` — `hub_resource_id` + four PDZ ids
      (`blob`, `vaultcore`, `azurecr`, `grafana`). 8/8 tests pass.
- [x] `bootstrap/environment/main.observability.tf`: `try(...)`-
      guarded the two legacy references to
      `environment.networking.grafana_pe_*` so the file still parses;
      **TODO comments** flag both call sites for Phase D rewiring
      (swap Grafana PE onto derived `snet-pe-env`; drop per-env zone
      for central `networking.private_dns_zones.grafana`).
- Verified: `terraform fmt -recursive` clean; `terraform validate`
  passes on `bootstrap/{fleet,environment}` after rendering
  `_fleet.yaml` from the CI fixture; `tflint --recursive` clean;
  `terraform test -test-directory=tests/unit` — `fleet-identity` 8/8
  pass, `init/` 30/30 pass.

## Phase D — `bootstrap/environment` env VNets + peerings + ASG

- [x] `terraform/bootstrap/environment/main.network.tf` (new):
  - `module "env_network"` → sub-vending `~> 0.2`,
    `subscription_alias_enabled = false`, `subscription_id = local.env_sub_id`,
    N = count of regions for this env (driven by
    `local.env_regions = { for k,v in networking_derived.envs : k=>v if v.env == var.env }`),
    `mesh_peering_enabled = true` per VNet, per-VNet
    `hub_peering_enabled = true` (direction = both),
    `enable_telemetry = false`. RG `rg-net-<env>` created via the
    module (`resource_group_creation_enabled = true`).
  - Per-region NSG `nsg-pe-env-<env>-<region>` authored via the
    module's `network_security_groups` + subnet `key_reference` (no
    inline rules; the ASG-bound rule needs
    `sourceApplicationSecurityGroups` which the module's schema does
    not expose, so it lives out-of-band as
    `azapi_resource.nsg_pe_env_rule_443`).
  - Per-region `azapi_resource.node_asg`
    (`Microsoft.Network/applicationSecurityGroups@2023-11-01`) named
    `asg-nodes-<env>-<region>`, parent = `rg-net-<env>`. Stage 1
    will attach AKS node-pool NICs to this id.
  - Subnet + NSG resource ids synthesised from the deterministic ARM
    paths (`<vnet-id>/subnets/<name>` and `<rg-id>/providers/.../<name>`)
    since sub-vending does not emit them.
  - Early `terraform_data.network_preconditions` rejects empty
    `networking.envs.<var.env>.regions`, missing region
    `address_space`, and unset / `<...>` / wrong-suffix
    `private_dns_zones.grafana` with yaml-anchored error messages.
- [x] `terraform/bootstrap/environment/main.peering.tf` (new):
  - One `module "mgmt_peering"` per region from
    `Azure/avm-res-network-virtualnetwork/azurerm//modules/peering ~> 0.17`
    with `parent_id = env_vnet_id`, `remote_virtual_network_id =
    var.mgmt_vnet_resource_id`, `name =
    networking_derived.envs[k].peering_env_to_mgmt_name`,
    `create_reverse_peering = true`, `reverse_name = ...peering_mgmt_to_env_name`.
  - `sync_remote_address_space_enabled = true` triggered on the env
    VNet's address_space so widening the env CIDR is reflected on
    the mgmt side without manual intervention. Reverse half is
    written cross-subscription via the `Network Contributor` grant
    that `bootstrap/fleet` issues to `uami-fleet-meta` on the mgmt
    VNet.
- [x] Rewire Grafana PE in `main.observability.tf`:
  - `subnet.id` → `local.env_snet_pe_env_id_by_region[local.env_location]`
    (lookup on the env's primary region; precondition fires if the
    region is not declared under `networking.envs.<env>.regions`).
  - Dropped per-env `azapi_resource.pdns_grafana` +
    `azapi_resource.pdns_grafana_links` (zone now owned centrally by
    the adopter under `networking.private_dns_zones.grafana`).
  - DNS zone group registers the PE A-record into
    `local.networking_central.pdz_grafana`.
  - Two `lifecycle.precondition` blocks on the PE: subnet not null,
    central PDZ id not null.
- [x] `outputs.tf`: added `env_region_vnet_resource_ids`,
      `env_region_node_asg_resource_ids`, `env_region_pe_subnet_ids`
      (the third is consumed by Stage 1 for cluster-leg PE rewiring;
      cheap to publish).
- [x] `main.github.tf`: `local.env_vars` is now `merge()` of the
      static env-scope vars + three per-region maps emitting
      `<ENV>_<REGION>_VNET_RESOURCE_ID`,
      `<ENV>_<REGION>_NODE_ASG_RESOURCE_ID`,
      `<ENV>_<REGION>_PE_SUBNET_ID` keys onto the existing
      `github_actions_environment_variable.env_vars` for_each.
      `env-bootstrap.yaml` does not need a separate publish step —
      the existing for_each picks up the new keys automatically.
- [x] `variables.tf`: added `mgmt_vnet_resource_id` (string,
      ARM-id-validated regex). Sourced by tf-apply.yaml from the
      `MGMT_VNET_RESOURCE_ID` repo-env variable that
      `bootstrap/fleet/main.github.tf` publishes onto `fleet-meta`.
- [x] `providers.tf`: added `modtm ~> 0.3` (sub-vending dependency)
      with empty `provider "modtm" {}` block; bumped to declare
      `random ~> 3.8` explicitly (also a sub-vending dep). `azapi
      ~> 2.9` already satisfies the peering submodule's `~> 2.0`
      requirement.
- Verified: `terraform fmt -recursive` clean; `terraform validate`
  passes on `bootstrap/{fleet,environment}` after rendering
  `_fleet.yaml` from the CI fixture; `tflint --recursive` clean;
  `terraform test` — `fleet-identity` 8/8, `init/` 30/30 pass.


## Phase E — Stage 1 per-cluster subnets + AKS integration

**Landed 2026-04-20** as a focused **networking slice** of PLAN §4
Stage 1 — the identity/RBAC/observability surface of PLAN §4 is
explicitly deferred to a follow-up (tracked in STATUS §4 Stage 1).
Design additions landed with this phase:

- **CGNAT pod CIDR** — `pod_cidr_slot` (0..15, immutable, fleet-unique)
  declared per env-region in `_fleet.yaml.networking.envs.*`; each
  cluster carves a `/16` at
  `100.[64 + pod_cidr_slot*16 + subnet_slot].0.0/16`. Wiring in
  `init/`, `modules/fleet-identity/`, `config-loader/load.sh`,
  consumed by Stage 1 `modules/aks-cluster/` as
  `network_profile.pod_cidr`. Docs in `docs/naming.md` "Pod CIDR
  allocation (CGNAT)" and PLAN §3.4.
- **AKS passthrough shape** — curated typed (`cluster.aks.<key>` →
  explicit variable in `modules/aks-cluster/variables.tf` → 1:1 AVM
  input). No freeform `extra` escape hatch. PLAN §3.4 "Stage 1 AKS
  module passthrough".
- **azurerm + random provider carveout** from the azapi-only
  invariant (PLAN §2) — required by the AVM AKS module's optional
  `management_lock`, `role_assignment`, `diagnostic_settings`
  features; we'll use the latter two in the RBAC + observability
  follow-ups.

- [x] `terraform/stages/1-cluster/main.network.tf`:
  - `azapi_resource.snet_aks_api` + `azapi_resource.snet_aks_nodes`
    as children of the env VNet (parent id from
    `var.env_region_vnet_resource_id`). CIDRs consumed from the
    loader tfvars. Lifecycle preconditions enforce `/28` on api,
    `>= /25` on nodes.
- [x] `terraform/modules/aks-cluster` (new AVM wrapper):
  - `Azure/avm-res-containerservice-managedcluster/azurerm ~> 0.5`
    (v0.5.3). Agent-pool
    `network_profile.application_security_groups = [var.node_asg_ids]`
    is supported natively — **no fallback path needed**. Apps pool
    goes through the sibling `//modules/agentpool` submodule (AVM
    v0.5 exposes only `default_agent_pool` at the root).
  - Two subnet ids (`api`, `nodes`) wired into
    `api_server_access_profile.subnet_id` (+ `enable_vnet_integration
    = true`) and `default_agent_pool.vnet_subnet_id` respectively.
  - Curated typed passthrough: `kubernetes_version`, `sku_tier`,
    `auto_scaler_profile`, `auto_upgrade_profile`, `system_pool`,
    `apps_pool` (all sourced from `_defaults.yaml` + `cluster.aks.*`
    overrides).
- [x] ~~ASG fallback path~~ — unnecessary; AVM v0.5.3 exposes
      `application_security_groups` on agent pools directly.
- [x] `terraform/modules/cluster-dns`:
  - Zone + two `virtualNetworkLinks` (keyed `{env, mgmt}`) authored
    via azapi. Link list takes `{env = <env vnet>, mgmt = <mgmt vnet>}`
    from Stage 1 vars (replaces the BYO-list read from cluster.yaml).
    Role assignment (external-dns UAMI → `Private DNS Zone
    Contributor`) deferred to the identity/RBAC follow-up.
- [x] `variables.tf` additions in `stages/1-cluster`:
  - `env_region_vnet_resource_id` (string, required, ARM-id regex).
  - `mgmt_vnet_resource_id` (string, required, ARM-id regex).
  - `node_asg_resource_id` (string, required, ARM-id regex).
  - `doc` (any) — the loader-produced merged JSON.
  - ~~`networking_subnet_slot`~~ — not needed as a separate input;
    `subnet_slot` is already carried in `var.doc.networking` and
    asserted via lifecycle.precondition on
    `terraform_data.network_preconditions`.
- [ ] tf-apply workflow: pipe env vars
      `<ENV>_<REGION>_VNET_RESOURCE_ID`,
      `<ENV>_<REGION>_NODE_ASG_RESOURCE_ID`,
      `MGMT_VNET_RESOURCE_ID` into `TF_VAR_*` for each cluster leg.
      **Deferred** — `tf-apply.yaml` does not yet exist (STATUS §10);
      piping lands when that workflow is written.

## Phase F — PR-check (validate.yaml)

- [ ] `.github/scripts/validate-subnet-slots.sh` (new):
  1. Glob `clusters/*/*/*/cluster.yaml`.
  2. Assert `networking.subnet_slot` is present and an integer.
  3. Compute VNet capacity per `<env>-<region>` from
     `_fleet.yaml.networking.envs.<env>.regions.<region>.address_space`
     (via `yq` + a tiny python CIDR helper).
  4. Assert slot in `[0, capacity-1]`.
  5. Assert uniqueness per `(env, region)`.
  6. On a PR, `git show main:<path>/cluster.yaml` for each changed
     file and assert `subnet_slot` did not change (immutability);
     hard-fail if it did with a pointer to the re-create migration
     path.
- [ ] Hook into `validate.yaml` as a required check.

## Phase G — Docs

- [ ] `docs/networking.md` (new):
  - Topology diagram (ASCII).
  - CIDR allocation rules (restate of PLAN §3.4 table, in
    operator-oriented language).
  - Peering matrix (hub, mgmt, each env-region).
  - Walkthrough: adding a new cluster (single PR, slot picking
    guidance, what to do when slots are exhausted).
  - Walkthrough: adding a second region to an env.
  - Fallback notes for NSP / ASG if agent-pool ASG is unsupported.
- [ ] `docs/naming.md` — Phase-A edits landed; double-check the
      table matches PLAN §3.3 after all phases applied.
- [ ] `docs/adoption.md` — update §3 / §5.1 field list to reflect
      the schema flip (Phase B). Add a pointer to
      `docs/networking.md`.
- [ ] `docs/onboarding-cluster.md` — flesh out the current stub
      into a concrete walkthrough covering `subnet_slot`, private
      DNS, and PR → Stage 1+2 flow.

## Phase H — Cleanup + STATUS finalization

- [ ] Re-run the template selftest
      (`./init-fleet.sh --non-interactive --values-file .github/fixtures/adopter-test.tfvars`
       in a throwaway clone); confirm rendered `_fleet.yaml` has the
      new networking shape.
- [ ] `terraform fmt -recursive` + `terraform validate` on every
      touched root.
- [ ] `tflint -r` clean.
- [ ] STATUS.md: flip every `[ ]` / `[~]` row this work closed; add
      new `[x]` rows where appropriate.
- [ ] PLAN.md §4 top-of-section "Implementation status (2026-04-20)
      — networking topology" callout: update from *"Implementation
      tracked in `_TASK.md`"* to *"Landed YYYY-MM-DD; see commit
      <sha>"*.
- [ ] **Delete `_TASK.md`** in the final commit. STATUS.md + PLAN
      §3.4 remain as the lasting record.

---

## Phase C followup — address_space shape fix

- [x] **Bug (Phase C):** `init/templates/_fleet.yaml.tftpl` rendered
      `address_space: ["10.x.0.0/20"]` (list) for mgmt + three env
      regions, but `modules/fleet-identity/networking_derived` passes
      the value through `cidrsubnet()` / `split("/", ...)` which
      require a scalar string, and `config-loader/load.sh` reads it
      via `jq -r '... .address_space'` which also expects a scalar.
      Only the sub-vending call site in
      `bootstrap/fleet/main.network.tf` L151 wraps it in `[...]`,
      which would have produced a list-of-list input to the AVM
      module. `terraform validate` does not evaluate `cidrsubnet()`
      so the mismatch was latent; the fleet-identity tests exercised
      the derivation with the correct scalar shape and hid it.
      Resolved by flipping the yaml shape to scalar string in the
      template, re-rendering, and updating the init test assertions
      that subscripted `address_space[0]`.

## Open questions to resolve in-flight

- [x] ~~`MGMT_VNET_RESOURCE_ID` publish path~~ — **resolved** (Phase C):
      published directly from `bootstrap/fleet`'s `main.github.tf` into
      the `fleet-meta` GitHub Environment's variables (option b in the
      original analysis). Stage 0 passthrough not needed.
- [ ] `allow_public_state_during_bootstrap` — retest on live apply
      once the mgmt VNet PE flow is in place. If PE-first from
      commit 0 works, simplify; else keep as-is.
- [ ] Sub-vending module required-providers: confirm full list
      (`azapi`, `random`, `modtm` are expected; may include more).
      Any transitive provider must be declared at every callsite.
