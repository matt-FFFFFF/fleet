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
      → `envs:` with new `envs.mgmt.location`. Input surface collapsed
      to a single `variable "environments"` of type
      `map(object({ subscription_id, address_space, hub_resource_id,
      mgmt_peering_target_env }))` — n-env extensible; mgmt key
      required by convention; per-env `hub_resource_id` required on
      non-mgmt, must be null on mgmt; `mgmt_peering_target_env`
      defaults to `"prod"` and is validated to name a real non-mgmt
      env. Template iterates the map with `%{ for env, cfg in
      environments }` loops to fan out `networking.hubs.<env>`,
      `networking.envs.<env>`, and top-level `envs.<env>` uniformly;
      mgmt env-region carries `mgmt_environment_for_vnet_peering:
      ${cfg.mgmt_peering_target_env}` and no hub entry; non-mgmt has
      no location field. `address_space` emitted as a YAML list;
      `create_reverse_peering` omitted (bootstrap default true).
      Pairwise address-space overlap validation rewritten with
      `setproduct(keys, keys)` so it scales to n envs. Removed
      scalars: `sub_mgmt`, `sub_nonprod`, `sub_prod`,
      `networking_hub_resource_id`,
      `networking_env_{mgmt,nonprod,prod}_address_space`. Kept:
      `primary_region`, `networking_pdz_*`. `sub_shared` also
      removed: `acr.subscription_id` + `state.subscription_id` are
      rendered directly from `environments["mgmt"].subscription_id`,
      since fleet-shared resources (ACR, tfstate SA, fleet KV) are
      PE-wired into the mgmt VNet's `snet-pe-fleet` and must live in
      the mgmt subscription. Adopter
      flow: top-level scalars carry `__PROMPT__` sentinels and are
      swept by `init-fleet.sh`; map-interior sentinels are
      intentionally ignored (prompt regex anchored at column 0) —
      adopters edit the `environments` map by hand. `--values-file`
      overlay rewritten to `cp` the file verbatim since fixture is
      exhaustive. `init/tests/unit/init.tftest.hcl` rewritten: 37
      runs pass, including `render_open_map_extra_env` (declares a
      `dev` env and asserts uniform fan-out into
      `hubs`/`networking.envs`/`envs`) + 14 `reject_environments_*`
      runs covering every validation rule. Schema addendum (unit 5):
      template now emits
      `networking.envs.<env>.regions.<region>.egress_next_hop_ip: null`
      for every env-region (moved out of
      `clusters/<env>/<region>/_defaults.yaml`); adopters edit
      `_fleet.yaml` post-init.
- [x] `clusters/_defaults.yaml` + env `_defaults.yaml`.
- [x] `clusters/_template/cluster.yaml` onboarding scaffold with
      `networking.subnet_slot` required field.
- [x] §3.2 DNS hierarchy; zone FQDN pattern encoded in `_fleet.yaml`.
- [~] §3.3 Derivation rules — `config-loader/load.sh` rework done
      (unit 3); `modules/fleet-identity/` done (unit 1). Parity
      contract between shell + HCL is re-established. Downstream
      Stage -1/0/1 consumers of `derived.networking` still consume
      the old output shape and land in units 4-7:
  - `config-loader/load.sh` — **done** (unit 3). `.environments` →
    `.envs` rename; comments rewritten to uniform env-region model
    (no "pre-Phase-B" wording, no `networking.vnets.mgmt`); mgmt
    no longer treated as singleton — the cluster's own env-region
    drives VNet/RG/subnet/NSG/route-table derivations uniformly
    whether env=mgmt or not; `address_space` parsed as YAML list
    (jq `.[0]`-ish pick before piping to Python); new derivations
    emitted: `snet_pe_env_{name,cidr}`, `nsg_pe_env_name`,
    `route_table_name`, `peer_mgmt_{region,vnet_name,net_resource_group}`
    + `peering_{spoke_to_mgmt,mgmt_to_spoke}_name` (null when
    env=mgmt) — mgmt region resolved by same-region-else-first
    rule mirroring `modules/fleet-identity/` local.mgmt_regions.
    Mgmt clusters additionally emit `snet_pe_fleet_{name,cidr}`,
    `snet_runners_{name,cidr}`, `nsg_{pe_fleet,runners}_name` via
    the Python CIDR helper (fleet zone = upper /(N+1); runners =
    first /23; pe-fleet = 8th /26 of the fleet zone) — Python
    raises a structured error if mgmt address_space is < /20.
     Manual smoke test vs the example clusters passes
     (`aks-mgmt-01` and `aks-nonprod-01`). No unit-test harness for
     load.sh yet; gap tracked as deferred. Schema addendum (unit 5):
     `egress_next_hop_ip` now read from
     `networking.envs.<env>.regions.<region>.egress_next_hop_ip` in
     `_fleet.yaml` (was previously sourced from the region-level
     `_defaults.yaml`); emitted in `derived.networking` passthrough.
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
    advanced in unit 8: `docs/naming.md` now matches post-rework
    derivations. Automated diff CI between `load.sh` and bootstrap
    HCL locals still `[ ]` (tracked as Rework-program item 12).
- [x] §3.4 Networking topology — spec rewritten in PLAN (commit
      143d18b) to uniform env-region model; implementation landed in
      units 4–7 of the Rework program (per-region mgmt VNets,
      fleet-plane zone, env=mgmt vs env≠mgmt branching in
      `bootstrap/environment`, DNS-link id-equality collapse + route
      table association in `stages/1-cluster`, ACR PE into
      `snet-pe-fleet` in `stages/0-fleet`). Docs swept in unit 8.
- [x] Example clusters: `mgmt/eastus/aks-mgmt-01`,
      `nonprod/eastus/aks-nonprod-01` — validated against post-rework
      schema during unit 3 smoke test.

## §4 Terraform stages

### Stage -1 — `terraform/bootstrap/`

- [~] `bootstrap/fleet/` — **rework done** (unit 4): aligned with
      PLAN §3.4 uniform env-region model. `main.network.tf` rewritten
      to `for_each` over `networking.envs.mgmt.regions.<region>` with
      one sub-vending invocation per mgmt region creating
      `vnet-<fleet>-mgmt-<region>` in `rg-net-mgmt-<region>`, fleet-plane
      subnets `snet-pe-fleet` (`/26`) + `snet-runners` (`/23`) at the
      HIGH end of each /20, NSGs `nsg-pe-fleet-<region>` +
      `nsg-runners-<region>`, hub peering against
      `networking.hubs.<mgmt_environment_for_vnet_peering>.regions.<region>.resource_id`.
      Network Contributor grant to `fleet-meta` fanned out per mgmt
      VNet. `main.state.tf` / `main.kv.tf` / `main.runner.tf` each
      select the co-located mgmt region (matching `acr_location` /
      `fleet_kv_location`) with same-region-else-first fallback +
      precondition for the strict case. `outputs.tf` exposes
      per-region maps `mgmt_vnet_resource_ids` /
      `mgmt_snet_pe_fleet_ids` / `mgmt_snet_runners_ids`.
      `main.github.tf` publishes them as JSON-encoded map vars
      `MGMT_VNET_RESOURCE_IDS` / `MGMT_PE_FLEET_SUBNET_IDS` /
      `MGMT_RUNNERS_SUBNET_IDS` on the `fleet-meta` environment
      (replacing the fleet-scope scalar `MGMT_VNET_RESOURCE_ID`).
      Cluster-workload subnet authoring moved out of this stage; now
      `bootstrap/environment`'s responsibility (unit 5). PLAN §3.4
      updated in lockstep to document the JSON-map variable shape.
      Validates cleanly against rendered `_fleet.yaml`.
  - [ ] GH Apps (`fleet-meta`, `stage0-publisher`, `fleet-runners`) —
        documented as TODO in `main.github.tf`; manifest-flow helper
        not written. Not affected by drift.
- [~] `bootstrap/environment/` — **rework done** (unit 5): aligned
      with PLAN §3.4 uniform env-region model. `variables.tf` renamed
      `.environments` → `.envs` in the fleet-yaml guard; scalar
      `var.mgmt_vnet_resource_id` removed and replaced with
      `var.mgmt_vnet_resource_ids` (map(string) keyed by mgmt region,
      fed from the JSON-encoded `MGMT_VNET_RESOURCE_IDS` GH env var
      published by `bootstrap/fleet`). `main.tf` collapses `envs` rename
      and derives `local.location` from `envs.mgmt.location` when
      env=mgmt, else first declared region under
      `networking.envs.<env>.regions`. `main.network.tf` rewritten
      into two branches: for `env != "mgmt"` the sub-vending module
      authors `rg-net-<env>-<region>` + `vnet-<fleet>-<env>-<region>`
      (one per region, `mesh_peering_enabled=true`) with only hub
      peering + NSG in-module (subnets empty so the env=mgmt branch
      stays uniform); for `env == "mgmt"` the pre-existing mgmt VNets
      (`var.mgmt_vnet_resource_ids[region]`) are used as parents
      directly and the env-PE NSG is created here. Uniform
      cluster-workload carves applied to both branches as azapi
      children: `snet-pe-env` (/26), `rt-aks-<env>-<region>` route
      table shell (per-region; `0.0.0.0/0` route entry conditional on
      `networking.envs.<env>.regions.<region>.egress_next_hop_ip`
      being non-null), `asg-nodes-<env>-<region>` ASG, and the
      443-from-node-ASG NSG rule. `main.peering.tf` rewritten to skip
      env=mgmt entirely (`for_each = local.is_mgmt ? {} : ...`);
      resolves the peer mgmt region via same-region-else-first
      (mirrors fleet-identity's peering-name derivation);
      `remote_virtual_network_id` per-region; honours
      `local.env_regions[k].create_reverse_peering` for both
      `create_reverse_peering` and `sync_remote_address_space_enabled`.
      `main.github.tf` + `outputs.tf` unchanged — the existing
      per-region maps (`env_vnet_id_by_region`, `node_asg`,
      `env_snet_pe_env_id_by_region`) keep their shapes under both
      branches. Schema-level additions: `egress_next_hop_ip` moved
      out of `clusters/<env>/<region>/_defaults.yaml` into
      `networking.envs.<env>.regions.<region>.egress_next_hop_ip` so
      the whole per-env-region networking surface lives in one place
      (see §3.1 / §3.3 below); PLAN §3.4 prose updated in lockstep.
      `terraform validate` + `fmt -check` + 45 unit tests
      (8 fleet-identity, 37 init) pass.
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
  - [x] Fleet ACR private from first apply via `snet-pe-fleet` PE
        (unit 7): `publicNetworkAccess = Disabled`; `azapi_resource.acr_pe`
        + `privateDnsZoneGroup` land in the mgmt VNet's `snet-pe-fleet`
        co-located with `acr.location` (same-region-else-first). New
        `var.mgmt_pe_fleet_subnet_ids` populated in CI from
        `fromjson(vars.MGMT_PE_FLEET_SUBNET_IDS)`, published on the
        `fleet-stage0` env by `bootstrap/fleet/main.github.tf`. PDZ id
        read from `networking.private_dns_zones.azurecr` with shape
        precondition. Mirrors the state SA / fleet KV PE pattern.

### Stage 1 — `terraform/stages/1-cluster`

- [~] Networking slice — **rework done** (unit 6): aligned with
      PLAN §3.4 uniform env-region model. `variables.tf` rewritten:
      scalar `var.mgmt_vnet_resource_id` replaced with
      `var.mgmt_region_vnet_resource_id` sourced per-cluster from
      `fromJSON(vars.MGMT_VNET_RESOURCE_IDS)[derived.networking.peer_mgmt_region]`
      (same-region-else-first resolution done in
      `config-loader/load.sh`); added `var.route_table_resource_id`
      sourced from `<ENV>_<REGION>_ROUTE_TABLE_RESOURCE_ID`; header
      comment rewritten. `main.tf` locals updated (`var.doc.fleet.environments`
      → `.envs` catching up with unit 3 rename; new `local.mgmt_cluster`
      flag from id-equality detection); preconditions block carries
      new error messages for `mgmt_region_vnet_resource_id` (map-index
      pipeline) and `route_table_resource_id` (ARM-id + egress next-hop
      note). `main.network.tf` sets `properties.routeTable.id` on both
      the api and nodes subnets (PLAN §3.4 UDR egress: api-server VNet
      integration + nodes share one next-hop). `main.aks.tf`
      `linked_vnet_ids` now collapses to a single `mgmt` link when
      `local.mgmt_cluster` (env and mgmt ids equal), else the two-entry
      `{env, mgmt}` map — collapse is id-equality driven, not `env ==
      "mgmt"`, so it's schema-agnostic. `providers.tf` header comment
      rewritten for the JSON-map pipeline. `bootstrap/environment`
      extended in the same unit: `outputs.tf` exposes
      `env_region_route_table_resource_ids` (map(region → rt id));
      `main.github.tf` publishes `<ENV>_<REGION>_ROUTE_TABLE_RESOURCE_ID`
      alongside the existing VNet/NodeASG/PE-subnet vars.
      `terraform validate` + `fmt -recursive` pass on both dirs.
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

- [x] `docs/adoption.md` — reworked: prompts table collapses four
      `sub_*` + two address-space rows + `networking_hub_resource_id`
      into a single `environments` map row; §3 post-init narrative +
      §5.1 prereqs reflect per-env-region `hub_network_resource_id`
      and per-mgmt-region VNet ownership.
- [x] `docs/networking.md` — reworked: Tiers table + topology
      Mermaid show per-mgmt-region VNets and nullable per-env-region
      hub refs; CIDR diagram + Mermaid show env-plane (first `/24`) /
      API pool (second) / nodes pool + mgmt-only fleet-plane zone in
      upper `/(N+1)` with `snet-runners` `/23` + `snet-pe-fleet`
      `/26`; derivation block includes the fleet-plane formulas;
      peering ownership table/sequence + peering-names table updated
      for per-mgmt-region selector (`same-region-else-first`) and
      env-owned both halves; DNS-link section documents id-equality
      collapse for mgmt clusters; repo-variables table carries the
      JSON-map `MGMT_*` set + per-(env,region) scalars incl.
      `ROUTE_TABLE_RESOURCE_ID`; new "Route table / UDR egress"
      section documents the unconditional shell + optional
      `0.0.0.0/0` route.
- [x] `docs/onboarding-cluster.md` — reworked: DNS-link paragraph
      names the per-cluster `peer_mgmt_region` resolution via
      `fromJSON(vars.MGMT_VNET_RESOURCE_IDS)` and documents the
      mgmt-cluster id-equality collapse; Stage 1 bullets reference
      `ROUTE_TABLE_RESOURCE_ID` on the per-cluster subnets and
      single-link collapse for mgmt clusters.
- [x] `docs/naming.md` — reworked: inputs section spells out
      `envs.<env>.subscription_id` (top-level) vs
      `networking.envs.<env>.regions.<region>.{address_space,
      hub_network_resource_id, egress_next_hop_ip}`; derived-names
      table uses uniform `vnet-<fleet>-<env>-<region>` /
      `rg-net-<env>-<region>`, adds `rt-aks-<env>-<region>` and
      `asg-nodes-<env>-<region>`, splits env-plane (`snet-pe-env`,
      `nsg-pe-env-<env>-<region>`) from mgmt-only fleet-plane
      (`snet-pe-fleet`, `snet-runners`, `nsg-pe-fleet-<region>`,
      `nsg-runners-<region>`) with correct CIDR formulas (runners
      `/23`, pe-fleet `/26` at index 8 of upper `/(N+1)`), and
      peering-names include the mgmt-region suffix.
- [ ] `onboarding-team.md`, `upgrades.md`, `promotion.md`.

## §12 Risks and mitigations

- Reference-only.

## §13 Phased implementation

- [~] **Phase 1 (Skeleton)** — in progress:
  - [x] Repo scaffold per §2.
  - [~] `_fleet.yaml` (generated) + `_defaults.yaml` — renderer
        PLAN-compliant after unit 2; end-to-end adoption flow still
        blocked on downstream consumers (`bootstrap/environment`,
        stages 0/1). See §3.1.
  - [~] `bootstrap/fleet` code; not applied; PLAN-compliant after
        unit 4 (mgmt VNet shells + fleet-plane subnets per-region).
  - [~] `bootstrap/environment` code; not applied; PLAN-compliant
        after unit 5 (env=mgmt vs non-mgmt branches, uniform
        cluster-workload carves, per-region peering,
        `mgmt_vnet_resource_ids` map).
  - [~] `stages/0-fleet` body; not applied; **rework done** (unit 7).
        Fleet ACR PE lands in the mgmt VNet's `snet-pe-fleet`
        (same-region-else-first); ACR flipped to
        `publicNetworkAccess = Disabled`; `MGMT_PE_FLEET_SUBNET_IDS`
        published on the `fleet-stage0` env.
  - [~] `stages/1-cluster` — **rework done** on mgmt VNet resolution
        (per-region via JSON-map index), DNS-link collapse for mgmt
        clusters, and route table association on both api and nodes
        subnets (unit 6). Identity/RBAC follow-up still pending.
  - [ ] `config-loader/load.sh` naming-derivation parity CI diff —
        loader itself matches (unit 3); automated diff between
        loader and bootstrap HCL locals still deferred
        (Rework-program item 12).
  - [ ] CI workflows (`validate`, `tf-plan`, `tf-apply`,
        `env-bootstrap`).
  - [ ] **Exit criterion** (both clusters provision and pull from
        fleet ACR) — not met; blocked on live apply
        (Rework-program item 10) + CI workflows (item 11).
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

- [x] §16.1 Single source of truth (`clusters/_fleet.yaml` generated)
      — renderer + consumers realigned to post-rework schema across
      units 1–7 + 5b (init template emits uniform
      `networking.envs.<env>.regions.<region>.*` + `envs.<env>`
      top-level; both bootstrap stacks read the new keys).
- [x] §16.2 Bootstrap TF reads yaml — both stacks read the
      post-rework schema (`envs` not `environments`, per-env-region
      `hub_network_resource_id` not `networking.hub`, no
      `networking.vnets.mgmt` block; mgmt VNet ids flow via
      `var.mgmt_vnet_resource_ids` map).
- [x] §16.3 `init-fleet.sh` wrapper over `init/` TF module.
- [x] §16.4 `init-gh-apps.sh` — manifest flow for `fleet-meta` /
      `stage0-publisher` / `fleet-runners` Apps; writes
      `./.gh-apps.state.json` + `./.gh-apps.auto.tfvars`; patches
      `_fleet.yaml` with runner IDs; self-deletes. Stage 0 wiring of
      the tfvars overlay remains TODO.
- [x] §16.5 GitHub template mechanics; `import` block for fleet repo.
- [x] §16.6 `docs/naming.md` — reworked in unit 8; see §11.
  - [ ] CI diff between `load.sh` and bootstrap HCL locals — deferred.
- [x] §16.7 Safety rails (banner, dirty-tree refusal, TF validation).
- [x] §16.8 Template self-test workflow. Selftest fixture will need
      updating to new schema in lockstep.
- [x] §16.9 File additions/modifications — uniform env-region
      networking schema landed across `init/templates/_fleet.yaml.tftpl`,
      `init/variables.tf`, `init/render.tf`, `config-loader/load.sh`,
      `modules/fleet-identity/`, `bootstrap/fleet/`,
      `bootstrap/environment/`, `stages/1-cluster/`,
      `stages/0-fleet/`, and docs (units 1–8 of Rework program).
      Schema simplification in unit 5b folded the top-level
      `networking.hubs` map into per-env-region
      `hub_network_resource_id` and dropped
      `mgmt_environment_for_vnet_peering`.
- [x] §16.10.1–9 Execution order complete.
  - [-] §16.10.10 CI naming-diff — deferred to Phase 2 CI work.

---

## Outside-PLAN scaffolding

- [x] `.fleet-initialized` marker contract.
- [x] `.github/fixtures/adopter-test.tfvars` selftest input —
      regenerated post-rework (unit 2; refreshed in unit 5b + the
      `sub_shared` removal side-trip).
- [x] `AGENTS.md` — agent onboarding preamble.
- [x] `terraform/modules/github-repo/` vendored fork. See
      `VENDORING.md` for upstream diff.
- [x] `terraform/modules/cicd-runners/` vendored fork. See
      `VENDORING.md` for upstream diff.
- [x] `terraform/modules/fleet-identity/` pure-function derivation
      module — rework landed in units 1 + 5b: schema contract matches
      PLAN §3.1/§3.3/§3.4 (uniform per-(env,region) map,
      mgmt-as-env-region, HIGH-end fleet zone, `snet_pe_fleet_cidr`
      rename, peering-name mgmt-region suffix, per-env-region
      `hub_network_resource_id` passthrough). Consumers in
      `bootstrap/fleet`, `bootstrap/environment`, `stages/1-cluster`
      rewired in units 4–6. 8 unit tests pass.
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
   `init/tests/unit/init.tftest.hcl` to emit the new schema. Input
   surface collapsed to a single `environments` map-of-objects so
   n envs are supported without renderer changes; template iterates
   the map to fan out `hubs` / `networking.envs` / `envs` uniformly;
   `init-fleet.sh` prompt regex anchored column-0 so map-interior
   sentinels are adopter-edited; `--values-file` overlay now `cp`s
   verbatim. 37 tests pass incl. `render_open_map_extra_env` +
   14 validation-rejection runs.
3. **Config loader — `terraform/config-loader/load.sh`**. ✅ **Done.**
   Rename `.environments` → `.envs`, rewrite comments to uniform
   env-region model, drop mgmt-singleton assumption, parse
   `address_space` as YAML list, add `snet-pe-env` / `snet-pe-fleet`
   / `snet-runners` / `nsg-pe-env` / `route-table` / `peering`
   derivations (peer mgmt region resolved by same-region-else-first
   rule), extend Python CIDR helper with mgmt fleet-plane carve
   (fleet zone = upper /(N+1); runners = first /23; pe-fleet = 8th
   /26) with `/20`-minimum guard. Manual smoke test vs example
   clusters (`aks-mgmt-01`, `aks-nonprod-01`) passes; no shell-level
   test harness landed (deferred).
4. **`bootstrap/fleet` network** — ✅ **Done.** Per-region mgmt VNet
   shells via `for_each` over `networking.envs.mgmt.regions.<region>`,
   fleet-plane subnets at the HIGH end of each /20,
   `snet-pe-shared` → `snet-pe-fleet` renamed throughout, per-region
   NSGs (`nsg-pe-fleet-<region>` / `nsg-runners-<region>`), per-region
   Network Contributor grants for `fleet-meta` on each mgmt VNet.
   Dropped fleet-scope `MGMT_VNET_RESOURCE_ID`; replaced with
   JSON-encoded map vars `MGMT_VNET_RESOURCE_IDS` /
   `MGMT_PE_FLEET_SUBNET_IDS` / `MGMT_RUNNERS_SUBNET_IDS` on the
   `fleet-meta` environment (keyed by region). `outputs.tf` converted
   to per-region maps. `main.state.tf` / `main.kv.tf` /
   `main.runner.tf` each resolve the co-located mgmt region
   (same-region-else-first) with preconditions. PLAN §3.4 updated to
   document the JSON-map variable shape. `terraform validate` +
   `terraform fmt -check` + all 45 unit tests (8 fleet-identity,
   37 init) pass.
 5. **`bootstrap/environment` network** — ✅ **Done.** `variables.tf`
    renamed `.environments` → `.envs` in fleet-yaml guard; scalar
    `var.mgmt_vnet_resource_id` replaced with per-region
    `var.mgmt_vnet_resource_ids` (map(string), non-empty, full
    ARM-id regex). `main.tf` `envs` rename + `local.location`
    defaulting to `envs.mgmt.location` for env=mgmt else first
    region under `networking.envs.<env>.regions`. `main.network.tf`
    rewritten into env=mgmt vs env≠mgmt branches: sub-vending
    (non-mgmt) authors `rg-net-<env>-<region>` + VNet shell + hub
    peering + NSG with `subnets = {}`; env=mgmt references
    `var.mgmt_vnet_resource_ids[region]` and creates env-PE NSG in
    `rg-net-mgmt-<region>`. Uniform cluster-workload carves
    (`snet-pe-env`, `rt-aks-<env>-<region>` with conditional
    `0.0.0.0/0` route, `asg-nodes-<env>-<region>`, 443-from-ASG
    NSG rule) applied as azapi children under both branches.
    `main.peering.tf` rewritten to guard env=mgmt
    (`for_each = local.is_mgmt ? {} : ...`); per-region peer VNet
    id resolved same-region-else-first; honours per-region
    `create_reverse_peering` for both the flag and
    `sync_remote_address_space_enabled`. Schema-level addition:
    `egress_next_hop_ip` moved from
    `clusters/<env>/<region>/_defaults.yaml` into
    `networking.envs.<env>.regions.<region>.egress_next_hop_ip` so
    the whole per-env-region networking surface lives in
    `_fleet.yaml`; `init/templates/_fleet.yaml.tftpl` emits `null`,
    `modules/fleet-identity/` + `config-loader/load.sh` pass it
    through. PLAN §3.4 prose updated in lockstep. `terraform
    validate` + `fmt -check` + all 45 unit tests pass.
 5b. **Schema simplification: fold `networking.hubs` into per-env-region
     `hub_network_resource_id`, drop `mgmt_environment_for_vnet_peering`** —
     ✅ **Done.** Decision: the top-level
     `networking.hubs.<env>.regions.<region>.resource_id` map is
     redundant with the per-env-region key, and `mgmt_environment_for_vnet_peering`
     is redundant because mgmt↔env peering is implicit from the mgmt
     key (only one env is named `mgmt`). Collapsed in
     `modules/fleet-identity/` (dropped `hubs_raw`/`hubs` flattener;
     added `hub_network_resource_id` passthrough on
     `networking_derived.envs.<env>/<region>`; nullable on all envs
     incl. mgmt; tests rewritten — 8/8 pass), `config-loader/load.sh`
     (added `hub_network_resource_id` jq lookup + emission; smoke-tested
     on mgmt + nonprod clusters), `bootstrap/fleet/main.network.tf`
     (per-region `hub_peering_enabled = each.value.hub_network_resource_id
     != null`; mgmt↔hub peering owned here; preflight allows null),
     `bootstrap/environment/main.network.tf` (per-region
     `hub_peering_enabled` conditional; env↔hub peering for env≠mgmt),
     plus a doc sweep in `variables.tf` / `outputs.tf` / `main.tf`
     headers + cluster `_defaults.yaml` comments. `init/variables.tf`
     (dropped `mgmt_peering_target_env`, renamed `hub_resource_id` →
     `hub_network_resource_id` nullable on every env incl. mgmt),
     `init/templates/_fleet.yaml.tftpl` (removed `networking.hubs`
     block, emits `hub_network_resource_id` per env-region with YAML
     null support), `init/tests/unit/init.tftest.hcl` (34/34 pass),
      `.github/fixtures/adopter-test.tfvars` refreshed. Also hardened
      `init-fleet.sh` dirty-tree guard to include untracked files via
      `git status --porcelain`. PLAN §3.4 prose + §3.1 YAML example +
      §4 bootstrap stages + §14 + §16.1 rewritten in lockstep (all
      `networking.hubs` / `mgmt_environment_for_vnet_peering` refs
      gone).
6. **Stage 1 rework** — ✅ **Done.** Replaced scalar
   `var.mgmt_vnet_resource_id` with per-region
   `var.mgmt_region_vnet_resource_id`, selected per-cluster by
   `fromJSON(vars.MGMT_VNET_RESOURCE_IDS)[derived.networking.peer_mgmt_region]`
   (loader does same-region-else-first resolution). Added
   `var.route_table_resource_id`; both the `/28` api subnet and the
   `/25` nodes subnet now set `properties.routeTable.id` so
   api-server VNet integration + node egress share one hub-firewall
   next-hop (PLAN §3.4 UDR). Added mgmt-cluster DNS-link collapse
   (`local.mgmt_cluster = env_region_vnet_resource_id ==
   mgmt_region_vnet_resource_id`) — schema-driven not
   `env=="mgmt"`-driven. Caught + fixed a stale `fleet.environments`
   → `fleet.envs` reference in `local.env_aks`. Extended
   `bootstrap/environment/outputs.tf` +
   `main.github.tf` to publish
   `<ENV>_<REGION>_ROUTE_TABLE_RESOURCE_ID` per region symmetric with
   the existing VNet/NodeASG/PE-subnet vars. Preconditions block +
   header comments rewritten on every touched file. `terraform
   validate` + `fmt -recursive` pass on `stages/1-cluster` and
   `bootstrap/environment`.
7. **Stage 0 ACR PE** — ✅ **Done.** Fleet ACR flipped to
   `publicNetworkAccess = Disabled` from the first apply;
   `azapi_resource.acr_pe` + `privateDnsZoneGroup` land in the mgmt
   VNet's `snet-pe-fleet` co-located with `acr.location` (same-region-
   else-first fallback). New `var.mgmt_pe_fleet_subnet_ids` (non-empty
   map with full-ARM-subnet-id shape validation) populated in CI from
   `fromjson(vars.MGMT_PE_FLEET_SUBNET_IDS)`; that repo variable is
   now published on the `fleet-stage0` env by
   `bootstrap/fleet/main.github.tf` (was `fleet-meta`-only). PDZ id
   sourced from `networking.private_dns_zones.azurecr` via a new
   `local.pdz_azurecr` read, with shape precondition on the PE.
   Mirrors the state SA / fleet KV PE selector pattern in
   `bootstrap/fleet`. `terraform validate` green on all four stacks;
   end-to-end smoke (`init-fleet.sh --non-interactive` + `validate` on
   `bootstrap/{fleet,environment}` + `stages/{0-fleet,1-cluster}`)
   passes clean.
8. **Docs** — ✅ **Done.** Reworked all four §11 drift targets in
   lockstep with units 1–7 + 5b: `docs/naming.md` (inputs section +
   derived-names table; uniform VNet/RG/NSG names, split env-plane
   vs mgmt-only fleet-plane subnets, correct CIDR formulas, peering
   names with mgmt-region suffix), `docs/networking.md` (Tiers +
   topology Mermaid for per-mgmt-region VNets and nullable
   per-env-region hub refs; CIDR diagram + Mermaid + derivation
   block for env-plane + API pool + nodes pool + mgmt-only
   fleet-plane zone; peering ownership table/sequence +
   peering-names table; DNS-link id-equality collapse; repo
   variables table with JSON-map `MGMT_*` set +
   `ROUTE_TABLE_RESOURCE_ID`; new "Route table / UDR egress"
   section), `docs/adoption.md` (prompts table collapsed into
   single `environments` map row; §3 post-init narrative + §5.1
   prereqs for per-env-region `hub_network_resource_id` and
   per-mgmt-region VNet ownership), `docs/onboarding-cluster.md`
   (DNS-link paragraph names `peer_mgmt_region` resolution via
   `fromJSON(vars.MGMT_VNET_RESOURCE_IDS)` and mgmt-cluster
   id-equality collapse; Stage 1 bullets reference
   `ROUTE_TABLE_RESOURCE_ID` on per-cluster subnets).
9. **Identity/RBAC Stage 1 follow-up** (pre-existing `[ ]`; gated
   by unit 6).
10. **Live apply** of `bootstrap/fleet` + `stages/0-fleet` against a
    real tenant (pre-existing `[ ]`; gated by units 1-7).
11. **CI workflows** (`validate`, `tf-plan`, `tf-apply`,
    `env-bootstrap`) — unblocks Phase 1 exit criterion.
12. **Naming-diff CI** between `load.sh` and bootstrap HCL locals
    (deferred, but should land before Phase 2).
