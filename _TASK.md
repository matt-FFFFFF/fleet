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

- [ ] **Pin AVM module versions.** Pick latest `~> X.Y` for:
  - `Azure/avm-ptn-alz-sub-vending/azure` (must satisfy
    `azapi ~> 2.5`).
  - `Azure/avm-res-network-virtualnetwork/azure//modules/peering`.
  Record both pins in this file below (replace `<pin>`); use them
  verbatim in every `source` / `version` pair.
  - sub-vending pin: `<pin>`
  - peering pin: `<pin>`
- [ ] **Verify AKS agent-pool ASG support.** In the pinned
  `Azure/avm-res-containerservice-managedcluster/azurerm` version,
  confirm `networkProfile.applicationSecurityGroups` is exposed on
  agent pools. Record verdict here:
  - [ ] Supported → Stage 1 passes ASG id on the agent pool directly.
  - [ ] Not supported → Stage 1 falls back to authoring NSG rules on
        `nsg-pe-env-<env>-<region>`; `bootstrap/environment` must
        pre-grant the `fleet-<env>` UAMI scoped `Network Contributor`
        on that NSG. Update PLAN §3.4 "Fallback" paragraph and this
        task list accordingly.

---

## Phase A — Derivation layer (pure, no cloud)

- [ ] Extend `terraform/modules/fleet-identity/` to emit (pure locals;
      no provider calls):
  - Mgmt VNet name/RG, `snet-pe-shared` / `snet-runners` CIDRs
    (first and second `/26` of mgmt `address_space`).
  - Env VNet name/RG per `<env>-<region>`, `snet-pe-env` CIDR (first
    `/26`).
  - Per-cluster `/24` from `networking.subnet_slot`
    (K-th `/24` after the reserved `/26`(s)).
  - `snet-aks-api-<cluster>` / `snet-aks-nodes-<cluster>` CIDRs
    (two `/25`s of the `/24`).
  - Peering names `peer-<env>-<region>-to-mgmt` /
    `peer-mgmt-to-<env>-<region>`.
  - ASG name `asg-nodes-<env>-<region>`.
  - VNet-capacity integer per env-region (for PR-check max slot).
- [ ] Add fixture cases + assertions to
      `terraform/modules/fleet-identity/tests/unit/fleet_identity.tftest.hcl`
      covering: default `/20` → 15 slots; slot 0, 7, 14 CIDR math;
      custom address_space; overlapping-slot detection left to
      PR-check (unit module is pure-input).
- [ ] Extend `terraform/config-loader/load.sh` with the same
      networking derivations so Stage 1 sees `snet-aks-api-*` /
      `snet-aks-nodes-*` CIDRs, the env VNet name, the peering
      names, and `node_asg_name` in its merged tfvars.json. Parity
      with the HCL module is the contract (PLAN §16.6 /
      `docs/naming.md`).
- [ ] Update `docs/naming.md` with the new rows (mirrors PLAN §3.3
      derivation table). Same commit as the code.

## Phase B — Schema flip (`_fleet.yaml` + `cluster.yaml`)

- [ ] `init/templates/_fleet.yaml.tftpl`:
  - Add `networking.hub.resource_id`,
    `networking.private_dns_zones.{blob,vaultcore,azurecr,grafana}`,
    `networking.vnets.mgmt.{location,address_space}`,
    `networking.envs.<env>.regions.<region>.address_space`.
  - Remove `networking.grafana_pe_subnet_id`,
    `networking.grafana_pe_linked_vnet_ids`,
    `networking.tfstate.private_endpoint.subnet_id`,
    `networking.fleet_kv.private_endpoint.subnet_id`,
    `networking.runner.subnet_id`,
    `networking.runner.container_registry_pe_subnet_id`.
    (Central DNS zone refs consolidate under
    `networking.private_dns_zones` — keep as BYO.)
- [ ] `init/variables.tf`: add typed vars + `validation {}` for
      every new adopter field (CIDR syntax, RFC1918 containment,
      /20 minimum, prod/nonprod/mgmt non-overlap).
- [ ] `init/inputs.auto.tfvars`: add `__PROMPT__` sentinels for the
      new fields; prompt text via inline comment.
- [ ] `init-fleet.sh`: no code change expected if prompts flow
      naturally; re-run `.github/fixtures/adopter-test.tfvars` to
      confirm.
- [ ] `clusters/_template/cluster.yaml`: add required
      `networking.subnet_slot: 0` with a comment pointing at PLAN
      §3.4; strip `networking.vnet_id`, `subnet_name`, and
      `dns_linked_vnet_ids`.
- [ ] JSON-schema / `validate.yaml` linter updates:
  - Require `networking.subnet_slot` integer `>= 0`.
  - Reject any BYO subnet field in cluster.yaml (fail loudly with
    a pointer to §3.4).
- [ ] `.github/fixtures/adopter-test.tfvars` + the two example
      clusters (`clusters/mgmt/eastus/aks-mgmt-01`,
      `clusters/nonprod/eastus/aks-nonprod-01`) — set concrete
      `subnet_slot` values (0 and 0 respectively; they are in
      different VNets).

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
