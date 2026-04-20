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

- [ ] `terraform/bootstrap/fleet/main.network.tf` (new):
  - `module "mgmt_vnet"` → sub-vending, N=1, no mesh,
    `hub_peering_enabled = true`,
    `enable_telemetry = false`.
  - NSGs `nsg-pe-shared` + `nsg-runners` authored via the module's
    NSG input (preferred) or as sibling `azapi_resource`s.
  - `rg-net-mgmt` resource group.
  - `azapi_resource` role assignment: `Network Contributor` on the
    mgmt VNet resource id → `fleet-meta` UAMI.
- [ ] Rewire existing PE/ACA consumers to derived subnet outputs:
  - `main.state.tf` — tfstate SA PE parent subnet.
  - `main.fleet-kv.tf` (or wherever the fleet KV PE lives) — fleet
    KV PE parent subnet.
  - `main.acr.tf` / wherever the fleet ACR PE lives (if one exists
    in this stage; otherwise remains in Stage 0).
  - `main.runner.tf` — ACA runner subnet id passed to the runner
    module.
- [ ] `providers.tf` / `versions.tf`: add `random` and `modtm`
      provider declarations required by the sub-vending module
      (inspect module's `required_providers` block to confirm
      exact list; add only what's missing).
- [ ] `outputs.tf`: add `mgmt_vnet_resource_id` (published to repo
      vars by the Stage 0 workflow as `MGMT_VNET_RESOURCE_ID` —
      passthrough, no Stage 0 code needed beyond the output list).
  - Alternative if simpler: output from Stage 0 via a passthrough
    data source, since Stage 0 already owns the publish pipeline.
    Decide at implementation time; update the §4 Stage 0 outputs
    table in PLAN if the former.

## Phase D — `bootstrap/environment` env VNets + peerings + ASG

- [ ] `terraform/bootstrap/environment/main.network.tf` (new):
  - `module "env_vnets"` → sub-vending, N = count of regions for
    this env, `mesh_peering_enabled = true`,
    per-VNet `hub_peering_enabled = true`,
    `enable_telemetry = false`. Inputs driven by
    `local.fleet.networking.envs[var.env].regions`.
  - `rg-net-<env>` resource group.
  - NSG `nsg-pe-env-<env>-<region>` per region with inbound `443`
    from `asg-nodes-<env>-<region>`.
  - `azapi_resource` ASG `asg-nodes-<env>-<region>` per region.
- [ ] `terraform/bootstrap/environment/main.peering.tf` (new):
  - For each region, one `module "mgmt_peering"` call using the
    peering AVM module with `create_reverse_peering = true`.
    Names per PLAN §3.4.
  - Depends on mgmt VNet being present (pre-existing, as
    `bootstrap/fleet` must apply first; capture via variable
    consuming `MGMT_VNET_RESOURCE_ID` repo var).
  - Workflow identity is `fleet-meta` with `Network Contributor`
    on the mgmt VNet id, granted by `bootstrap/fleet` — so both
    halves succeed in the same apply.
- [ ] Rewire Grafana PE:
  - Swap `azapi_resource.grafana_pe` parent subnet from
    `local.environments[var.env].networking.grafana_pe_subnet_id`
    to the derived `snet-pe-env` subnet id output by the
    sub-vending module.
  - Drop the per-env `privatelink.grafana.azure.com` zone creation;
    register the PE into the central BYO zone under
    `local.fleet.networking.private_dns_zones.grafana`.
- [ ] `outputs.tf`: add
  - `env_region_vnet_resource_ids` map → published as
    `<ENV>_<REGION>_VNET_RESOURCE_ID` per region.
  - `env_region_node_asg_resource_ids` map → published as
    `<ENV>_<REGION>_NODE_ASG_RESOURCE_ID` per region.
- [ ] Update `env-bootstrap.yaml` publish step to create/patch
      those per-region variables on the `fleet-<env>` GitHub
      environment (same mechanism as the obs outputs).

## Phase E — Stage 1 per-cluster subnets + AKS integration

- [ ] `terraform/stages/1-cluster/main.network.tf` (new):
  - `azapi_resource.snet_aks_api` + `azapi_resource.snet_aks_nodes`
    as children of the env VNet (parent id from
    `var.env_region_vnet_resource_id`). CIDRs consumed from the
    loader tfvars.
- [ ] `terraform/modules/aks-cluster` (wrap AVM module):
  - Agent-pool `networkProfile.applicationSecurityGroups = [var.node_asg_resource_id]`
    **if supported** by the pinned module version.
  - Wire the two new subnet ids into the AVM module's AKS network
    profile inputs.
- [ ] If ASG fallback path is in effect: add Stage 1 azapi author of
      NSG rules on `nsg-pe-env-<env>-<region>` (scoped to the new
      node subnet prefix); require `bootstrap/environment` to grant
      `Network Contributor` on that NSG to `fleet-<env>`.
- [ ] `terraform/modules/cluster-dns` (update):
  - Derive `dns_linked_vnet_ids = [env_vnet_id, mgmt_vnet_id]`
    (from repo vars) instead of reading the BYO list from
    cluster.yaml.
- [ ] `variables.tf` additions in `stages/1-cluster`:
  - `env_region_vnet_resource_id` (string, required)
  - `mgmt_vnet_resource_id` (string, required)
  - `node_asg_resource_id` (string, required)
  - `networking_subnet_slot` (number, required; echoes cluster.yaml)
- [ ] tf-apply workflow: pipe env vars
      `<ENV>_<REGION>_VNET_RESOURCE_ID`,
      `<ENV>_<REGION>_NODE_ASG_RESOURCE_ID`,
      `MGMT_VNET_RESOURCE_ID` into `TF_VAR_*` for each cluster leg.

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

## Open questions to resolve in-flight

- [ ] `MGMT_VNET_RESOURCE_ID` publish path — Phase C captures the
      value in `bootstrap/fleet` outputs, but the repo-variable
      publisher is the Stage 0 workflow. Either (a) add the
      variable to Stage 0's publish list as a passthrough via a
      small `azapi_resource_action` / data-source read, or (b) add
      a one-off step in the `bootstrap/fleet` local flow +
      `fleet-meta` workflow to `gh api PUT` the var directly. Prefer
      (a) for consistency with existing Stage 0 outputs; spec
      accordingly when writing the code.
- [ ] `allow_public_state_during_bootstrap` — retest on live apply
      once the mgmt VNet PE flow is in place. If PE-first from
      commit 0 works, simplify; else keep as-is.
- [ ] Sub-vending module required-providers: confirm full list
      (`azapi`, `random`, `modtm` are expected; may include more).
      Any transitive provider must be declared at every callsite.
