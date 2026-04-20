# STATUS

> **What this is.** A mirror of `PLAN.md`'s section structure recording
> **what exists in the repo right now**. `PLAN.md` answers "what should
> be"; this file answers "what is". Section numbers match `PLAN.md`.
>
> **Discipline.** Every commit that closes a PLAN sub-item updates the
> matching line here in the same commit. Deviations from PLAN go into a
> short "Implementation status" callout inside the relevant PLAN section
> (see §16 for the pattern) AND get reflected here.
>
> Legend: `[x]` done · `[~]` in progress / scaffolded but unapplied
> `[ ]` not started · `[-]` deferred.

Last updated: 2026-04-20 · **Phase E (Stage 1 networking slice)**
landed on `feat/networking-topology`. `terraform/stages/1-cluster/`
root now authors the per-cluster `/28` api + `/25` nodes subnets as
`azapi_resource` children of the env VNet, invokes a new
`terraform/modules/aks-cluster/` wrapper around
`Azure/avm-res-containerservice-managedcluster/azurerm ~> 0.5`
(curated-typed `cluster.aks.*` passthrough; Entra-only auth + OIDC
+ workload identity + private cluster + VNet integration + Azure CNI
Overlay + Cilium hard-coded per PLAN §4), and creates the per-cluster
private DNS zone via a new `terraform/modules/cluster-dns/` with
`virtualNetworkLinks` to `[env, mgmt]`. Also this session:
**per-cluster CGNAT pod CIDR** — new `pod_cidr_slot` (0..15, immutable,
unique) per env-region block in `_fleet.yaml.networking.envs.*`
reserves a `/12` at `100.[64 + slot*16].0.0/12`, and every cluster
carves a `/16` at `100.[64 + pod_cidr_slot*16 + subnet_slot].0.0/16`.
Wiring lands in `init/templates/_fleet.yaml.tftpl`, `init/variables.tf`
+ `inputs.auto.tfvars`, `modules/fleet-identity/main.tf` + outputs,
`config-loader/load.sh` (python3 validator), and is consumed by Stage
1 as `network_profile.pod_cidr`. Docs: `docs/naming.md` grew a new
"Cluster pod CIDR" row + "Pod CIDR allocation (CGNAT)" subsection;
also **fixed a stale capacity table** (`/21`=12 was `10`, `/22`=4 was
`2`; HCL + template were already correct). `azurerm + random` carveout
(PLAN §2) documented in provider files — AVM AKS module authors the
cluster via azapi but ships optional `azurerm_management_lock` /
`azurerm_role_assignment` / `azurerm_monitor_diagnostic_setting`, and
the RBAC follow-up will use the latter two. Verification: Stage 1 +
both new modules `terraform validate` clean; `fleet-identity` 8/8 +
`init/` 33/33 (was 30/30) tests green. Remaining Stage-1 surface
(cluster KV, UAMIs, role assignments, managed Prometheus DCR/DCRA +
rules, Kargo mgmt rotation) tracked in §4 Stage 1; Phase F (PR-check)
+ Phase G (docs) + Phase H (cleanup) in `_TASK.md`.

Prior: Two-pool subnet layout (pre-Phase-E refactor) landed on
`feat/networking-topology`. PLAN §3.4 rewrote the per-cluster CIDR
math from "symmetric `/24` slot split into two `/25`s" to a two-pool
design: each env-region VNet reserves its first `/24` for PE/runners,
its second `/24` as the **API pool** (16 × `/28` delegated to
`Microsoft.ContainerService/managedClusters` — AKS requires exactly
`/28`), and the remaining `/24`s as the **nodes pool** (2 × `/25` per
`/24`, sized for Azure CNI Overlay + Cilium where pod IPs come from
`pod_cidr`). `subnet_slot: i` now indexes both pools simultaneously.
New capacity formula `min(16, 2 * (2^(24-N) - 2))` — `/20` yields 16
slots (api-pool-bound). Updated: PLAN §3.3 derivation table + §3.4
layout diagram + prose, `docs/naming.md`, `config-loader/load.sh`
python3 block, `modules/fleet-identity/main.tf` capacity locals +
outputs.tf doc, `modules/fleet-identity/tests/unit/` (16 replaces 15
at `/20`; new `/21`=12 and `/22`=4 assertions),
`clusters/_template/cluster.yaml` comment.

Prior: Phase D (bootstrap/environment env VNets +
peerings + ASG) landed on `feat/networking-topology`. New
`main.network.tf` invokes `Azure/avm-ptn-alz-sub-vending/azure ~> 0.2`
with `subscription_alias_enabled = false` against `local.env_sub_id`,
N = count of regions for this env, `mesh_peering_enabled = true` per
VNet, per-VNet `hub_peering_enabled = true` (direction = both). Creates
`rg-net-<env>` + per-region `vnet-<fleet>-<env>-<region>` + reserved
`/26` `snet-pe-env` + per-region NSG `nsg-pe-env-<env>-<region>`.
Per-region `asg-nodes-<env>-<region>` authored as a plain
`azapi_resource` (no AVM ASG module). Inbound 443 from the node ASG
to `snet-pe-env` is added out-of-band as
`azapi_resource.nsg_pe_env_rule_443` because sub-vending's
`security_rules` schema does not expose
`sourceApplicationSecurityGroups`. New `main.peering.tf` invokes the
peering AVM submodule (`Azure/avm-res-network-virtualnetwork/azurerm//modules/peering ~> 0.17`,
azapi-only despite the parent module being azurerm) once per region
with `create_reverse_peering = true`, `parent_id = env_vnet_id`,
`remote_virtual_network_id = var.mgmt_vnet_resource_id`, and
`sync_remote_address_space_enabled = true`. The reverse half writes
cross-subscription using the `Network Contributor` grant
`bootstrap/fleet` issued to `uami-fleet-meta` on the mgmt VNet.
Grafana PE rewired to derived `snet-pe-env` in `local.env_location`,
DNS zone group registers into central
`networking.private_dns_zones.grafana`; per-env `pdns_grafana` zone
+ links removed entirely. New `mgmt_vnet_resource_id` input (ARM-id
regex-validated). New `outputs.tf` entries
`env_region_{vnet,node_asg,pe_subnet}_resource_ids`; `main.github.tf`
publishes `<ENV>_<REGION>_{VNET_RESOURCE_ID,NODE_ASG_RESOURCE_ID,PE_SUBNET_ID}`
onto `fleet-<env>` via the existing `for_each`. `providers.tf` now
declares `modtm ~> 0.3` + `random ~> 3.8` (sub-vending deps).
`terraform validate` passes on `bootstrap/{fleet,environment}`,
`tflint --recursive` clean, `fleet-identity` 8/8 + `init/` 30/30
tests still green. Remaining: Phases E–H tracked in `_TASK.md`.

Prior: Phase C follow-up — `address_space` shape bug fix on
`feat/networking-topology`:
`init/templates/_fleet.yaml.tftpl` was rendering
`networking.vnets.mgmt.address_space` and each
`networking.envs.<env>.regions.<region>.address_space` as a
**list** (`["10.50.0.0/20"]`) but every consumer —
`modules/fleet-identity`'s `cidrsubnet()` / `split("/", ...)` math,
`config-loader/load.sh`'s `jq -r`, and
`bootstrap/fleet/main.network.tf` which already wraps in `[...]`
before passing to the AVM sub-vending module — expects a scalar
string. `terraform validate` doesn't evaluate `cidrsubnet()` so the
mismatch was latent; fleet-identity tests hid it by using scalar
fixtures. Flipped the template to emit scalars; updated the two
init test assertions that were indexing `address_space[0]`.

Prior: Phase C (bootstrap/fleet mgmt VNet) landed
on `feat/networking-topology`: new `main.network.tf` invokes
`Azure/avm-ptn-alz-sub-vending/azure ~> 0.2` with
`subscription_alias_enabled = false` (we run against the already-
bootstrapped shared sub) to create `vnet-<fleet>-mgmt` in `rg-net-mgmt`
with two reserved /26 subnets (`snet-pe-shared`, `snet-runners`), NSGs
`nsg-pe-shared` + `nsg-runners`, ACA delegation on the runner subnet,
and hub peering (`direction = both`) to `networking.hub.resource_id`.
Three existing PE consumers rewired to the derived subnet +
central-PDZ outputs: tfstate SA PE (blob), fleet KV PE (vaultcore),
ACA runner pool (runner subnet + ACR PE subnet + azurecr zone).
`fleet-meta` UAMI gets `Network Contributor` on the mgmt VNet scope
so `bootstrap/environment` can author the reverse half of every
mgmt↔env peering. `MGMT_VNET_RESOURCE_ID` published as a repo-env
variable on the `fleet-meta` GitHub Environment (direct publish from
bootstrap/fleet; no Stage 0 passthrough). `modules/fleet-identity`
replaced its legacy `networking` output (all null after Phase B) with
`networking_central` (hub + 4 PDZ ids); 8/8 tests still pass. CI
fixture renders cleanly and `terraform validate` passes on
`bootstrap/{fleet,environment}`; `tflint --recursive` clean. Phase B
(schema flip) + Phase A (derivation layer) landed earlier on this
branch. Remaining implementation (Phases D–H) tracked in `_TASK.md`.

---

## §1 Decisions (locked)

- [x] All Phase-1 decisions captured. No open locks.

## §2 Repository layout

- [x] Top-level scaffold (`clusters/`, `terraform/`, `docs/`, `.github/`).
- [x] `init/` throwaway module + `init-fleet.sh` (see §16).
- [ ] `platform-gitops/` — Phase 2+.

## §3 Cluster config schema

- [x] §3.1 `clusters/_fleet.yaml` — rendered by `init/`; template lives
      at `init/templates/_fleet.yaml.tftpl`. Fleet identity, ACR,
      state SA, AAD apps, observability, per-env blocks. Networking
      shape flipped 2026-04-20 (Phase B): `networking.{hub,
      private_dns_zones,vnets.mgmt,envs.<env>.regions.<region>}`;
      legacy `{tfstate,runner,fleet_kv}` + per-env `grafana_pe_*`
      fields removed. 9 new init vars + validation + sentinels.
- [x] `clusters/_defaults.yaml` + env `_defaults.yaml` (mgmt has
      node_pools override; nonprod/prod are `{}`).
- [x] `clusters/_template/cluster.yaml` onboarding scaffold.
      Networking block flipped to `subnet_slot: 0` 2026-04-20 (Phase B,
      PLAN §3.4); BYO `vnet_id`/`subnet_name`/`dns_linked_vnet_ids`
      removed.
- [x] §3.2 DNS hierarchy documented; zone FQDN pattern encoded in
      `_fleet.yaml`.
- [~] §3.3 Derivation rules in `config-loader/load.sh`:
  - [x] Subscription stitching from `_fleet.yaml.environments.<env>`.
  - [ ] Full name-derivation parity with `docs/naming.md` — pending
        audit against bootstrap-stage HCL locals.
  - [~] Networking derivations — fleet-scope + env-scope landed in
        `modules/fleet-identity/` (Phase A, 2026-04-20); cluster-scope
        (`subnet_slot` → two-pool `/28` api + `/25` nodes CIDRs, plus
        subnet/peering/ASG names) landed in `load.sh` via an inline
        python3 `ipaddress` helper. Missing: HCL consumers in
        `bootstrap/{fleet,environment}` + Stage 1 (Phases C/D/E).
- [~] §3.4 Networking topology — **spec + derivation + schema flip +
      mgmt VNet + env VNets/peerings/ASG + Stage 1 networking slice +
      CGNAT pod CIDR.** Phase A (derivation):
      `fleet-identity` emits `networking_derived.{mgmt, envs}`;
      `load.sh` emits `.derived.networking.*` per cluster. Phase B
      (schema): `_fleet.yaml.tftpl` + `cluster.yaml` template +
      example clusters carry the new networking shape; `init/`
      validates 9 new adopter fields (now 12 with `pod_cidr_slot`).
      Phase C (mgmt VNet): `bootstrap/fleet` authors mgmt VNet + subnets
      + NSGs + hub peering via sub-vending `~> 0.2`; tfstate/KV/runner
      PEs rewired to derived subnets + central PDZs; `fleet-meta` UAMI
      gets Network Contributor on the mgmt VNet;
      `MGMT_VNET_RESOURCE_ID` published to the `fleet-meta` GH
      Environment. Phase D (env VNets): `bootstrap/environment`
      authors `rg-net-<env>` + per-region env VNets + `snet-pe-env`
      + `nsg-pe-env-*` via sub-vending (mesh + hub peering); per-region
      `asg-nodes-*` ASG via azapi; mgmt↔env peerings via the peering
      AVM submodule with `create_reverse_peering = true`; Grafana PE
      rewired to derived `snet-pe-env` + central PDZ; per-region
      `<ENV>_<REGION>_*` repo-env vars published. **Phase E
      (Stage 1 networking):** `stages/1-cluster/` root +
      `modules/aks-cluster/` + `modules/cluster-dns/` land per-cluster
      subnets, AKS cluster (AVM wrapper with curated passthrough), and
      private DNS zone with VNet links to `[env, mgmt]`. **CGNAT pod
      CIDR** — `pod_cidr_slot` per env-region (0..15, immutable,
      fleet-unique) reserves a `/12`; per-cluster `/16` at
      `100.[64 + pod_cidr_slot*16 + subnet_slot].0.0/16`. Remaining:
      Stage-1 identity/RBAC surface (cluster KV, UAMIs, role
      assignments, managed Prometheus, Kargo rotation), Phase F
      PR-check, Phases G/H docs + cleanup. Tracked in `_TASK.md`.
- [x] Example clusters: `mgmt/eastus/aks-mgmt-01`,
      `nonprod/eastus/aks-nonprod-01` — networking blocks flipped to
      `subnet_slot: 0` (2026-04-20, Phase B); both in distinct env
      VNets so sharing slot 0 is valid.

## §4 Terraform stages

### Stage -1 — `terraform/bootstrap/`

- [~] `bootstrap/fleet/` — scaffolded (state SA, stage0 + meta UAMIs,
      FICs, GH repo + `main`-branch **ruleset**, env variables,
      private tfstate SA endpoint, self-hosted runner pool).
      Delivered via the vendored `terraform/modules/github-repo` and
      `terraform/modules/cicd-runners` modules.
      **Not yet applied against a live tenant.**
  - [x] yamldecode locals; no `var.fleet`.
  - [x] `import` block for `module.fleet_repo.github_repository.this[0]`.
  - [x] OIDC subject claims use ID-based keys
        (`repository_owner_id`, `repository_id`, `environment`).
  - [ ] GH Apps (`fleet-meta`, `stage0-publisher`, `fleet-runners`) —
        documented as TODO in `main.github.tf`; manifest-flow helper
        not written.
  - [~] Fleet Key Vault **relocated from Stage 0** (PLAN §4 Stage -1
        Implementation status 2026-04-19). Private-endpoint KV with
        Deny-default ACLs and central `privatelink.vaultcore.azure.net`
        DNS wiring; Key Vault Secrets User role assignment for
        `uami-fleet-runners` issued in the same apply graph. PEM
        seeding moves to post-bootstrap `init-gh-apps.sh`.
  - [~] Private endpoint on tfstate SA + Deny-default network ACLs
        with first-apply-only `allow_public_state_during_bootstrap`
        escape hatch. Scaffolded; awaits live apply. 2026-04-20
        (Phase C): PE subnet rewired from BYO `networking.tfstate.*`
        to derived `snet-pe-shared` in the repo-owned mgmt VNet; DNS
        zone group now unconditional against `networking.private_dns_zones.blob`.
  - [~] Self-hosted runner pool (ACA+KEDA, GH App auth via KV ref,
        bring-your-own VNet, per-pool ACR + LAW, no NAT/public IP).
        Scaffolded via `module "runner"` in `main.runner.tf`. First
        job execution awaits operator-supplied PEM via
        `init-gh-apps.sh`. 2026-04-20 (Phase C): subnet inputs
        rewired to derived `snet-runners` (ACA) + `snet-pe-shared`
        (ACR PE); ACR DNS zone now `networking.private_dns_zones.azurecr`.
  - [x] Mgmt VNet (sub-vending `~> 0.2`, N=1, no mesh, hub_peering
        direction=both) + `rg-net-mgmt` + `snet-pe-shared` /
        `snet-runners` subnets + NSGs `nsg-pe-shared` + `nsg-runners`
        + ACA delegation on runner subnet. `Network Contributor` on
        mgmt VNet → `fleet-meta` UAMI (for reverse-peering writes
        from `bootstrap/environment`). `MGMT_VNET_RESOURCE_ID`
        published to the `fleet-meta` GitHub Environment variables
        directly from this stage. `main.network.tf` +
        `terraform_data.network_preconditions`. tfstate SA / fleet
        KV PEs rewired to `snet-pe-shared` + central PDZs. Fleet
        ACR PE rewire deferred (owned by Stage 0). `bootstrap/fleet`
        still not applied live. PLAN §3.4.
- [~] `bootstrap/environment/` — scaffolded (state container, env
      UAMI, GH env + variables, observability RG/AG/AMG/AMW/DCE/NSP).
      GH env + UAMI delivered via the vendored
      `modules/github-repo/modules/environment` submodule. Not yet
      applied. 2026-04-20 (Phase D): env VNets + intra-env mesh + hub
      peering + per-region NSG/ASG + mgmt↔env peerings + Grafana PE
      rewire all landed (see §3.4 / §4 Stage -1 Phase D status
      paragraph above). `bootstrap/environment` still not applied
      live.
  - [x] yamldecode locals; `var.location` optional.
  - [x] Consumes `fleet_meta_principal_id` input from fleet outputs.
  - [x] Consumes `mgmt_vnet_resource_id` input (sourced by tf-apply
        from `MGMT_VNET_RESOURCE_ID` repo-env variable published by
        `bootstrap/fleet`); ARM-id regex-validated.
  - [x] OIDC subject claims match fleet (ID-based); FIC name preserved
        via `identity.fic_name = "gh-fleet-<env>"` override.
  - [x] Env VNets via sub-vending `~> 0.2`
        (`mesh_peering_enabled = true`, per-VNet `hub_peering_enabled = true`)
        + `rg-net-<env>` + `snet-pe-env` (first /26 of region
        address_space) + `nsg-pe-env-<env>-<region>`. Address space
        sourced from `networking.envs.<env>.regions.<region>.address_space`.
        PLAN §3.4.
  - [x] Mgmt↔env peerings via the peering AVM submodule
        (`Azure/avm-res-network-virtualnetwork/azurerm//modules/peering ~> 0.17`,
        azapi-only) with `create_reverse_peering = true`. Reverse
        half writes cross-subscription using the Network Contributor
        grant `bootstrap/fleet` issued to `uami-fleet-meta` on the
        mgmt VNet. `sync_remote_address_space_enabled = true`
        triggered on env address_space.
  - [x] Per-env-region node ASG `asg-nodes-<env>-<region>` authored
        as `azapi_resource.node_asg` (no AVM ASG module exists).
        Stage 1 will attach AKS node-pool NICs via
        `agent_pools.*.network_profile.application_security_groups`.
  - [x] Inbound 443 from node ASG to `snet-pe-env` authored
        out-of-band as
        `azapi_resource.nsg_pe_env_rule_443` (sub-vending's
        `security_rules` schema does not support
        `sourceApplicationSecurityGroups`).
  - [x] Per-region repo-variable publishes
        `<ENV>_<REGION>_VNET_RESOURCE_ID` +
        `<ENV>_<REGION>_NODE_ASG_RESOURCE_ID` +
        `<ENV>_<REGION>_PE_SUBNET_ID` via the existing
        `github_actions_environment_variable.env_vars` for_each
        (no separate publish step). Grafana PE rewired to derived
        `snet-pe-env` + central
        `networking.private_dns_zones.grafana`; per-env zone +
        links removed.
- [~] `bootstrap/team/` — refactored onto the vendored module
      (`module "team_repo"` with `template =` + CODEOWNERS file);
      awaits PLAN §4 Stage -1 `team-bootstrap.yaml` CI flow.

### Stage 0 — `terraform/stages/0-fleet`

- [~] Scaffolded; **not yet applied**:
  - [x] ACR (Premium, zone-redundant, admin disabled).
  - [x] Fleet Key Vault **consumed, not created** — KV owned by
        `bootstrap/fleet` (PLAN §4 Stage -1 Implementation status
        2026-04-19); this stage references the KV by derived id and
        holds `Key Vault Secrets Officer` at vault scope for
        rotations.
  - [x] Argo AAD application + service principal.
  - [x] Argo RP `client_secret` rotation (60d cadence via `time_rotating`,
        `create_before_destroy`, `.value` written to fleet KV).
  - [x] Kargo AAD application + service principal (password deferred to
        mgmt Stage 1 per PLAN).
  - [x] Kargo mgmt UAMI (`uami-kargo-mgmt`) + `AcrPull` on the fleet ACR.
  - [x] Redirect URIs derived from the cluster inventory (`fileset` +
        `yamldecode`); mgmt redirects filtered on `cluster.role`.
  - [x] Outputs exported per PLAN §4 Stage 0 table (consumed as repo
        vars by Stage 1/2).
  - [-] `MGMT_VNET_RESOURCE_ID` passthrough output — **not needed**.
        Resolved 2026-04-20 (Phase C) by publishing the variable
        directly from `bootstrap/fleet`'s `main.github.tf` onto the
        `fleet-meta` GitHub Environment, rather than routing it
        through Stage 0 (the VNet is authored by the stage that
        publishes its id; no passthrough required). PLAN §4 Stage 0
        outputs table unchanged.
  - [ ] Fleet ACR private endpoint rewire — Stage 0 owns the ACR;
        the PE currently references legacy BYO networking fields
        that were removed in Phase B. Rewire to
        `local.snet_pe_shared_id` (via a `MGMT_SNET_PE_SHARED_ID`
        repo var output by `bootstrap/fleet`) + central
        `networking.private_dns_zones.azurecr` DNS zone. Tracked
        until Stage 0 is next touched.

### Stage 1 — `terraform/stages/1-cluster`

- [~] **Phase E (networking slice) landed 2026-04-20** on
      `feat/networking-topology`. Stage 1 root now exists with
      `providers.tf`/`backend.tf`/`variables.tf`/`main.tf`/
      `main.network.tf`/`main.aks.tf`/`outputs.tf`; consumes the
      loader tfvars via `var.doc` (typed as `any` — loader contract is
      the schema) plus three named repo-variable inputs
      (`env_region_vnet_resource_id`, `mgmt_vnet_resource_id`,
      `node_asg_resource_id`). `terraform_data.network_preconditions`
      fail-fasts on the six required fields before any Azure call.
      Remaining Stage-1 surface (cluster KV, UAMIs, role assignments,
      managed Prometheus DCR/DCRA + rules, Kargo mgmt rotation, RBAC
      Cluster Admin to `fleet-<env>` UAMI) stays TODO — tracked below
      and lands in the identity/RBAC follow-up.
- [x] Per-cluster subnets (`snet-aks-api-<name>` /28 delegated +
      `snet-aks-nodes-<name>` /25) authored as `azapi_resource`
      `Microsoft.Network/virtualNetworks/subnets@2023-11-01` children
      of the env VNet (`parent_id = var.env_region_vnet_resource_id`).
      Lifecycle preconditions enforce `/28` on api and `>= /25` on
      nodes. PLAN §3.4 / §4 Stage 1.
- [x] `terraform/modules/aks-cluster/` — wrapper around
      `Azure/avm-res-containerservice-managedcluster/azurerm ~> 0.5`
      (v0.5.3). **Curated typed passthrough** — explicit variables
      (`kubernetes_version`, `sku_tier`, `auto_scaler_profile`,
      `auto_upgrade_profile`, `system_pool`, `apps_pool`) map 1:1 to
      AVM inputs; no freeform `extra` map. Hard-coded: Entra-only
      auth (`disable_local_accounts`, `aad_profile.managed`,
      `enable_azure_rbac`, tenant/admin groups from `_fleet.yaml`),
      OIDC issuer on, workload identity on, private cluster with
      api-server VNet integration on the `/28` subnet, Azure CNI
      Overlay + Cilium, user-assigned cluster UAMI (`uami-aks-<name>`).
      Apps pool authored via the sibling
      `//modules/agentpool` submodule (AVM v0.5 exposes only
      `default_agent_pool` at the root). Node pools attach to the
      env-region ASG via `network_profile.application_security_groups
      = [var.node_asg_resource_id]`. PLAN §3.4 / §4 Stage 1.
- [x] `terraform/modules/cluster-dns/` — azapi-authored
      `Microsoft.Network/privateDnsZones` + one
      `virtualNetworkLinks` per entry in `linked_vnet_ids`
      (Stage 1 passes `{env, mgmt}`). `registrationEnabled = false`
      (external-dns owns record writes). Role assignment
      (`Private DNS Zone Contributor` → external-dns UAMI) deferred
      to the identity/RBAC phase. PLAN §3.4.
- [x] **Pod CIDR derivation (CGNAT):** per-env-region `pod_cidr_slot`
      (0..15, immutable, fleet-unique — validated in `init/`) reserves
      a `/12` envelope at `100.[64 + slot*16].0.0/12`, and every cluster
      carves a `/16` at `100.[64 + pod_cidr_slot*16 + subnet_slot].0.0/16`.
      Wired in `init/templates/_fleet.yaml.tftpl` (3 new scalar keys),
      `init/variables.tf` + `inputs.auto.tfvars`,
      `modules/fleet-identity/main.tf` (`networking_derived.envs.<k>`
      now emits `pod_cidr_slot` + `pod_cidr_envelope`),
      `config-loader/load.sh` (python3 block validates [0,15] + third
      octet ≤ 127; emits `.derived.networking.{pod_cidr, pod_cidr_slot}`),
      and consumed by the Stage 1 AKS module
      (`network_profile.pod_cidr`). 33/33 init tests + 8/8
      fleet-identity tests pass. Also fixed stale
      `docs/naming.md` capacity table (`/21`=12 was `10`, `/22`=4 was
      `2`; `fleet-identity/main.tf` and the cluster.yaml template
      were already correct — docs-only bug).
- [~] Provider set: **azurerm + random carveout** (PLAN §2) declared
      in `stages/1-cluster/providers.tf` + `modules/aks-cluster/terraform.tf`.
      The AVM AKS module authors the cluster via azapi but ships
      `azurerm_management_lock` / `azurerm_role_assignment` /
      `azurerm_monitor_diagnostic_setting` as optional features; we
      plan to use `diagnostic_settings` (→ Log Analytics) and
      `role_assignments` in the RBAC follow-up, so propagating both
      providers is intended not worked-around.
- [ ] **Deferred Stage-1 surface (identity/RBAC follow-up):**
      cluster Key Vault + KV Secrets User on ESO UAMI; UAMIs for
      external-dns / ESO / per-team; role assignments (AcrPull on
      kubelet, RBAC Cluster Admin for `fleet-<env>` UAMI + AAD groups,
      RBAC Reader for Kargo mgmt UAMI on every workload cluster,
      Private DNS Zone Contributor on the cluster zone, Monitoring
      Metrics Publisher on env AMW); managed Prometheus DCR/DCRA +
      `prometheusRuleGroups`; Kargo mgmt OIDC secret rotation + KV
      write. PLAN §4 Stage 1.
- [ ] `tf-apply.yaml` workflow (PLAN §10) — pipes `MGMT_VNET_RESOURCE_ID` +
      `<ENV>_<REGION>_{VNET,NODE_ASG}_RESOURCE_ID` into `TF_VAR_*`
      for each cluster leg. Today Stage 1 accepts them as ordinary
      tfvars; workflow piping is documentation-only until §10 lands.
- [ ] `validate.yaml` PR-check: `subnet_slot` present, integer,
      in-range, unique within env+region, immutable (change blocks
      PR). PLAN §3.4 Phase F.

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

- [~] Design locked in PLAN; identity seeds (UAMIs, FICs) scaffolded
      in Stage -1. ESO + KV wiring pending Stage 2.

## §9 RBAC

- [x] Design locked; per-env group bindings expressed as empty `[]`
      with `TODO` comments in rendered `_fleet.yaml` for post-init
      fill-in. `bootstrap/fleet` preconditions catch unfilled fleet-scope
      fields (null, empty, `<...>` sentinel, or non-`/subscriptions/...`
      ARM ids) before any provider call; `bootstrap/environment` does
      not yet guard every TODO uniformly — header of rendered
      `_fleet.yaml` says so explicitly.

## §10 CI/CD

- [ ] `validate.yaml`, `tf-plan.yaml`, `tf-apply.yaml`,
      `env-bootstrap.yaml`, `team-bootstrap.yaml` — not yet written.
      Runner selection (`runs-on: [self-hosted]` vs `ubuntu-latest`)
      per PLAN §10 → *Runner selection* to be encoded at that time.
- [x] `.github/workflows/template-selftest.yaml` — implemented
      (template-side only; removed by `init-fleet.sh` for adopters).
- [x] `.github/workflows/status-check.yaml` — enforces STATUS
      discipline on PRs touching tracked paths (template-side only;
      removed by `init-fleet.sh` for adopters).
- [x] `.github/workflows/tflint.yaml` + `.tflint.hcl` — recursive
      tflint on every PR; `terraform_unused_declarations` and
      `terraform_naming_convention` enforced. Kept in adopter repos.
- [x] `terraform test` unit suites (template-side; deleted with the
      rest of the template scaffolding by `init-fleet.sh`):
  - `init/tests/unit/init.tftest.hcl` — mocks `hashicorp/local`;
    round-trips rendered `_fleet.yaml` / CODEOWNERS / README /
    marker content; exercises every `validation {}` block in
    `init/variables.tf` via `expect_failures`.
  - `terraform/modules/fleet-identity/tests/unit/fleet_identity.tftest.hcl`
    — derivation contract (docs/naming.md) against the canonical
    fixture, overrides, 24-char truncation, networking try-paths.
  - Wired into `.github/workflows/template-selftest.yaml` ahead of
    the `init-fleet.sh` run.

## §11 Operator UX

- [x] `docs/adoption.md` — adopter flow. Will need refresh when
      §3.4 lands in code (BYO subnet fields drop; `networking.hub` +
      address_space fields added).
- [ ] `docs/networking.md` — **new** file per PLAN §3.4 (topology
      diagram, CIDR rules, peering matrix, `subnet_slot` walkthrough).
      Not yet written.
- [ ] `docs/onboarding-cluster.md`, `onboarding-team.md`,
      `upgrades.md`, `promotion.md` — stubs / not written.

## §12 Risks and mitigations

- Reference-only; no work items.

## §13 Phased implementation

- [~] **Phase 1 (Skeleton)** — in progress:
  - [x] Repo scaffold per §2.
  - [x] `_fleet.yaml` (generated) + `_defaults.yaml`.
  - [~] `bootstrap/fleet` code; not applied.
  - [~] `bootstrap/environment` code; not applied.
  - [~] `stages/0-fleet` body — scaffolded, not applied.
  - [ ] Example cluster `cluster.yaml` content validated against
        loader.
  - [ ] `stages/1-cluster` body + `aks-cluster` + `cluster-identities`.
  - [ ] `config-loader/load.sh` naming-derivation parity.
  - [ ] CI workflows (`validate`, `tf-plan`, `tf-apply`,
        `env-bootstrap`).
  - [ ] **Exit criterion** (both clusters provision and pull from
        fleet ACR) — not met.
- [ ] Phase 2 (ArgoCD bootstrap).
- [ ] Phase 3 (Platform services pre-Kargo).
- [ ] Phase 4 (Kargo install).
- [ ] Phase 5 (Platform promotion rollout).
- [ ] Phase 6 (Team tenancy + promotion).
- [ ] Phase 7 (Hardening).

## §14 Resolved Phase-1 configuration

- Reference-only (decisions captured in PLAN); no work items.

## §15 Remaining open items (deferred)

- Reference-only.

## §16 Template-repo adoption model

- [x] §16.1 Single source of truth (`clusters/_fleet.yaml` generated).
- [x] §16.2 Bootstrap TF reads yaml (both stacks refactored).
- [x] §16.3 `init-fleet.sh` wrapper over `init/` TF module. Adopter
      walkthrough hardening: awk-based hint extraction (BSD-sed
      portability), `github_repo` / `team_template_repo` prompted
      (not silently defaulted).
- [x] §16.4 `init-gh-apps.sh` — implemented at repo root; manifest
      flow for `fleet-meta` / `stage0-publisher` / `fleet-runners`
      Apps, writes `./.gh-apps.state.json` + `./.gh-apps.auto.tfvars`,
      patches `clusters/_fleet.yaml` with runner IDs, self-deletes
      on success. Stage 0 wiring of the tfvars overlay remains TODO.
      Adopter walkthrough hardening: manifest JSON handed to python
      via argv rather than stdin (heredoc-vs-pipe clash).
- [x] §16.5 GitHub template mechanics; `import` block for fleet repo.
- [x] §16.6 `docs/naming.md` drafted.
  - [ ] CI diff between `load.sh` and bootstrap HCL locals — deferred.
- [x] §16.7 Safety rails (banner, dirty-tree refusal, TF validation).
- [x] §16.8 Template self-test workflow.
- [x] §16.9 All file additions/modifications landed.
- [x] §16.10.1–9 Execution order complete.
  - [-] §16.10.10 CI naming-diff — deferred to Phase 2 CI work.

---

## Outside-PLAN scaffolding

- [x] `.fleet-initialized` marker contract (written by `init/`,
      committed, checked by `init-fleet.sh --force`).
- [x] `.github/fixtures/adopter-test.tfvars` selftest input.
- [x] `AGENTS.md` — agent onboarding preamble.
- [x] `terraform/modules/github-repo/` — vendored fork of
      `terraform-github-repository-and-content` (root + `modules/environment`
      + `modules/ruleset`). Repo-local extensions: `is_template`,
      `allow_{merge_commit,squash_merge,rebase_merge}`,
      `delete_branch_on_merge`, `vulnerability_alerts`,
      `environments[*].identity.fic_name`, hard-coded
      `lifecycle.ignore_changes` on `github_repository.this`. See
      `VENDORING.md` for upstream diff.
- [x] Terraform floor raised to `~> 1.11` across `init/`, all
      bootstrap stacks, Stage 0, and `template-selftest.yaml`.
- [x] `main`-branch protection on the fleet repo migrated from
      `github_branch_protection` to the vendored `modules/ruleset`
      (Kargo-bot bypass deferred per PLAN §10 / §15).
- [x] `terraform/modules/cicd-runners/` — vendored fork of
      `Azure/terraform-azurerm-avm-ptn-cicd-agents-and-runners`
      `v0.5.2` (root + `modules/container-app-job` +
      `modules/container-app-environment` + `modules/container-app-acr`).
      Repo-local extensions: `github_app_key_kv_secret_id` +
      `github_app_key_identity_id` inputs (KV-reference form);
      telemetry stripped; providers pinned to repo convention. See
      `VENDORING.md` for upstream diff.
- [x] `allow_public_state_during_bootstrap` first-apply-only
      variable on `bootstrap/fleet` (tfstate SA
      `publicNetworkAccess` toggle; defaults `false`; network ACLs
      remain `defaultAction = "Deny"`).
- [x] `terraform/modules/fleet-identity/` — pure-function module
      (no providers) that derives the fleet's canonical resource
      names + networking identifiers + GH-App coordinates from a
      parsed `_fleet.yaml`. Called from both `bootstrap/fleet` and
      `bootstrap/environment`; covered by
      `tests/unit/fleet_identity.tftest.hcl` (8 run blocks).
      2026-04-20 extension (PLAN §3.4): new `networking_derived`
      output — `mgmt.{vnet_name, rg_name, address_space, location,
      snet_pe_shared_cidr, snet_runners_cidr, cluster_slot_capacity}`
      and `envs["<env>/<region>"].{..., snet_pe_env_cidr,
      peering_env_to_mgmt_name, peering_mgmt_to_env_name,
      node_asg_name, nsg_pe_name, cluster_slot_capacity}`. 2026-04-20
      (Phase C): legacy `networking` output (BYO per-service subnet
      ids, all null after Phase B) replaced by `networking_central`
      exposing `hub_resource_id` + four `privatelink.*` PDZ ids
      (blob, vaultcore, azurecr, grafana). Test suite kept at 8
      runs; one now exercises `networking_central` passthrough.

## Next likely units of work

1. Land the PLAN §3.4 networking topology end-to-end (tracked in
   `_TASK.md`): schema flip in `_fleet.yaml` + `cluster.yaml`,
   `fleet-identity` derivations, `bootstrap/fleet` mgmt VNet,
   `bootstrap/environment` env VNets + peerings + ASG, Stage 1
   per-cluster subnets + ASG attachment, docs + PR-check.
2. Land `aks-cluster` + `cluster-identities` modules + `stages/1-cluster`.
3. First live apply of `bootstrap/fleet` + `stages/0-fleet` against a real
   tenant; record any drift here.
4. `validate.yaml` + `tf-plan.yaml` CI workflows.
5. CI parity check between `load.sh` naming and bootstrap / Stage 0
   HCL locals.
