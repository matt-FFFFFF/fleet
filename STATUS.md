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
  - [x] Naming parity sub-item (`docs/naming.md` vs bootstrap HCL locals)
    landed: unit 8 aligned the prose; Rework item 12 added automated
    CI diff between `load.sh` and `modules/fleet-identity/` over every
    shared fleet-scope + env-region-scope field (see §10 `naming-parity`
    job). Cluster-scope fields (snet_aks_api/nodes_*, per-cluster KV)
    are loader-only by design — fleet-identity has no cluster input.
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
  - [x] Identity/RBAC follow-up (rework unit 9): cluster KV
        (`modules/cluster-kv`); UAMIs (`uami-{external-dns,eso,team-<team>}-<cluster>`)
        in `main.identities.tf`; role assignments in `main.rbac.tf`
        (Private DNS Zone Contributor on cluster zone → external-dns
        UAMI; KV Secrets User on cluster KV + fleet KV → ESO UAMI;
        AcrPull on fleet ACR → kubelet identity; AKS RBAC Cluster
        Admin on this cluster → `fleet-<env>` UAMI + every
        `envs.<env>.aks.rbac_cluster_admins` group; AKS RBAC Reader →
        every `rbac_readers` group; AKS Cluster User Role → union of
        both group lists; AKS RBAC Reader → Kargo mgmt UAMI on every
        non-mgmt cluster; Monitoring Metrics Publisher on env AMW →
        cluster UAMI when managed-prometheus is enabled). Managed
        Prometheus DCR/DCRA + 3 recording rule groups
        (`modules/cluster-monitoring`) wired in `main.monitoring.tf`,
        gated on `platform.observability.managed_prometheus.enabled`
        (default true). AVM `azureMonitorProfile.metrics.enabled`
        plumbed through `modules/aks-cluster` (new
        `managed_prometheus_enabled` var); `kubelet_identity` exposed
        as a passthrough output. Mgmt-cluster-only Kargo OIDC secret
        rotation in `main.kv.tf` (`time_rotating` 60d +
        `azuread_application_password` `create_before_destroy` 90d
        end_date + azapi KV secret write); gated on
        `cluster.role == "management"`. New Stage 1 inputs:
        `fleet_keyvault_id`, `acr_resource_id`,
        `kargo_mgmt_uami_principal_id`, `kargo_aad_application_object_id`
        (nullable), `fleet_env_uami_principal_id`,
        `env_monitor_workspace_id`, `env_dce_id`, `env_action_group_id`.
        `bootstrap/environment/main.github.tf` publishes
        `FLEET_ENV_UAMI_PRINCIPAL_ID` env-scope. Outputs filled out to
        the full PLAN §4 Stage 1 surface (cluster_keyvault_*,
        external_dns_identity_*, eso_identity_*, team_identities,
        prometheus_dcr_id, env_*_id passthroughs).
        `providers.tf` reintroduces `azuread ~> 3.0` + `time ~> 0.12`
        (mgmt-only resources, declared unconditionally for uniform
        provider surface). `docs/naming.md` extended with
        external-dns / ESO / team UAMI rows + Prometheus DCR /
        DCRA / DCEA / 3 rule-group rows.
- [x] Pod CIDR / service CIDR hard-coded fleet-wide constants
      (`100.64.0.0/16` / `100.127.0.0/16`) in `modules/aks-cluster`.
- [x] `validate.yaml` subnet_slot PR-check (presence, type, range,
      uniqueness, immutability).
- [x] `tf-apply.yaml` workflow — see §10.

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

- [x] `validate.yaml` — multi-job consolidation: `terraform fmt
      -check -recursive`, `tflint --recursive` (absorbed from the
      removed `tflint.yaml`), `yamllint --strict clusters/` with a
      new top-level `.yamllint` baseline, the existing subnet-slot
      validator, and (new) a `naming-parity` job that diffs
      `config-loader/load.sh` against `modules/fleet-identity/` via
      a throwaway TF harness at `.github/scripts/naming-parity/` +
      `.github/scripts/check-naming-parity.sh`. Template-vs-adopter
      mode preserved (template-mode renders `clusters/_fleet.yaml`
      from the test fixture; adopter-mode asserts the committed file).
- [x] `tf-plan.yaml` — PR trigger; `detect` job runs
      `.github/scripts/detect-affected-clusters.sh` (new) emitting
      `{stage0, clusters}`; conditional `stage0` leg
      (`environment: fleet-stage0`, self-hosted, OIDC) + per-cluster
      matrix (`environment: fleet-<env>`, self-hosted, OIDC) rendering
      tfvars via `config-loader/load.sh` and running Stage 1 plan;
      `summarize` job downloads all plan artefacts and upserts a
      single sticky PR comment via `tf-summarize` (tree view) +
      collapsible full plan. Stage 2 plan block present but
      commented-out pending `stages/2-bootstrap/`.
- [x] `tf-apply.yaml` — push-to-main; same `detect` script; Stage 0
      leg runs first serially and captures every Stage 0 output;
      `publish-stage0` job scaffolded (`if: false`) to push outputs
      to fleet-scope repo variables via the `stage0-publisher`
      GitHub App (PEM from fleet KV) — flip on once
      `init-gh-apps.sh` + the App land (deferred sub-item below);
      per-cluster single-job matrix applies Stage 1 with
      `max-parallel: 1` for `env == prod`. Stage 2 apply block
      (including Stage 1→2 output pipe + AAD token mint) scaffolded
      as a commented-out TODO in the same job.
- [x] `env-bootstrap.yaml` — `workflow_dispatch` with
      `{env, action: plan|apply}`, `environment: fleet-meta`
      (2-reviewer gate), self-hosted, runs
      `terraform/bootstrap/environment` for the named env.
- [x] `team-bootstrap.yaml` — push-to-main on
      `platform-gitops/config/teams/*.yaml`; `detect` job
      `--diff-filter=A` picks up newly-added team YAMLs only; per-team
      matrix runs `terraform/bootstrap/team` under
      `environment: fleet-meta`.
- [x] `.github/scripts/detect-affected-clusters.sh` — shared
      change-detection helper consumed by `tf-plan` + `tf-apply`.
      Classifies diff into `stage0=bool` + affected `clusters[]` per
      PLAN §10 path-filter rules.
- [x] `.github/workflows/template-selftest.yaml` (template-side only).
- [x] `.github/workflows/status-check.yaml` (template-side only).
- [-] `.github/workflows/tflint.yaml` — deleted; folded into
      `validate.yaml` as the `tflint` job.
- [x] `terraform test` unit suites (template-side): `init/tests/unit/`
      and `modules/fleet-identity/tests/unit/`. **Tests will need
      updating** in lockstep with §3.1/§3.3 schema rework.

### §10 deferred (new sub-items)

- [ ] JSON-schema validation of merged `cluster.yaml` +
      `platform-gitops/config/teams/*.yaml` (PLAN §10
      `validate.yaml` bullets 3-4). Needs schema files authored.
- [ ] `.github/scripts/lint-teams.sh` team-config linter (PLAN §10
      `validate.yaml` bullet 5 — filename regex, forbidden fields,
      `oidcGroup` uniqueness, `services[].imageRepo` prefix, cluster
      path resolution). Needs `platform-gitops/config/teams/` to
      exist.
- [ ] `helm lint` over `platform-gitops/components/*` (PLAN §10
      `validate.yaml` bullet 6). Needs the components directory.
- [ ] `kargo lint` over `platform-gitops/kargo/**` (PLAN §10
      `validate.yaml` bullet 7). Needs kargo promotion directory.
- [ ] `stage0-publisher` GitHub App + `init-gh-apps.sh` helper
      (PLAN §16.4) — unblocks the `publish-stage0` job in
      `tf-apply.yaml` (currently `if: false`). Also requires a
      `.github/scripts/mint-gh-installation-token.sh` helper.
- [ ] `terraform/stages/2-bootstrap/` module — unblocks the Stage 2
      plan/apply blocks scaffolded (commented-out) in `tf-plan.yaml`
      + `tf-apply.yaml`. Also requires
      `.github/scripts/mint-aks-token.sh` (curl/jq recipe in PLAN §4
      Stage 2).
- [ ] Nightly drift-detection workflow (PLAN §10 "Drift detection").

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
  - [x] `config-loader/load.sh` naming-derivation parity CI diff —
        loader itself matches (unit 3); automated diff between loader
        and `modules/fleet-identity/` HCL locals landed as Rework item
        12 (`naming-parity` job in `validate.yaml`).
  - [x] CI workflows (`validate`, `tf-plan`, `tf-apply`,
        `env-bootstrap`, `team-bootstrap`) — see §10.
  - [ ] **Exit criterion** (both clusters provision and pull from
        fleet ACR) — not met; blocked on live apply
        (Rework-program item 10).
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
  - [x] CI diff between `load.sh` and bootstrap HCL locals — Rework
        item 12 (`naming-parity` job).
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
  - [x] §16.10.10 CI naming-diff — Rework item 12 (`naming-parity`
        job in `validate.yaml`).

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
9. **Identity/RBAC Stage 1 follow-up** — done. Single PR-sized
   commit lands cluster KV, per-cluster UAMIs (external-dns + ESO +
   per-team), every role assignment listed in PLAN §4 Stage 1
   (Private DNS Zone Contributor, KV Secrets User × 2, AcrPull, AKS
   RBAC Cluster Admin/Reader/User × group-set, Kargo Reader on
   workload clusters, Monitoring Metrics Publisher on env AMW),
   managed Prometheus DCR/DCRA/DCEA + 3 recording rule groups (node,
   k8s, UX), AVM `azureMonitorProfile.metrics` wiring, mgmt-only
   Kargo OIDC client-secret rotation (60d). New tfvars:
   `fleet_keyvault_id`, `acr_resource_id`,
   `kargo_mgmt_uami_principal_id`, `kargo_aad_application_object_id`,
   `fleet_env_uami_principal_id`, `env_{monitor_workspace,dce,action_group}_id`.
   `FLEET_ENV_UAMI_PRINCIPAL_ID` published env-scope by
   `bootstrap/environment`. Outputs filled to the full PLAN §4
   Stage 1 surface. `docs/naming.md` extended with the new UAMI +
   Prometheus DCR/DCRA + rule-group rows. `providers.tf` reintroduces
   `azuread ~> 3.0` + `time ~> 0.12` (mgmt-only resources, declared
   unconditionally for uniform provider surface across legs).
10. **Live apply** of `bootstrap/fleet` + `stages/0-fleet` against a
    real tenant (pre-existing `[ ]`; gated by units 1-7).
11. **CI workflows** — ✅ **Done.** Single PR-sized commit lands
    five workflows + one shared script. `validate.yaml` consolidated
    (fmt + tflint + yamllint + subnet-slots); `tflint.yaml` deleted.
    `tf-plan.yaml` (PR, dynamic per-cluster matrix,
    `tf-summarize` sticky comment) + `tf-apply.yaml` (push-to-main,
    Stage 0 leg → scaffolded publish step → per-cluster Stage 1
    apply with prod-serial) + `env-bootstrap.yaml`
    (`workflow_dispatch`, `fleet-meta`) + `team-bootstrap.yaml`
    (push-to-main on new team YAMLs, `fleet-meta`). All
    state-writing workflows `runs-on: [self-hosted]` per PLAN §10.
    `detect-affected-clusters.sh` shared between plan + apply.
    Stage 2 + `stage0-publisher` publish step scaffolded as
    commented-out / `if: false` TODOs tracked under §10 deferred
    sub-items. All action `uses:` refs pinned to SHAs via `pinact`.
12. **Naming-diff CI** between `load.sh` and `modules/fleet-identity/`
    HCL locals — ✅ **Done.** Single commit lands a throwaway TF
    harness at `.github/scripts/naming-parity/main.tf` (consumes
    `modules/fleet-identity/` and emits `derived` + `networking_derived`
    as JSON), a diff script `.github/scripts/check-naming-parity.sh`
    (runs loader per cluster, compares shared fleet-scope +
    env-region-scope fields, exits non-zero on any mismatch with a
    labelled diff), and a new `naming-parity` job in `validate.yaml`
    that renders `_fleet.yaml` (template-mode) or verifies the
    committed file (adopter-mode) before running the check. Verified
    locally: passes clean on both example clusters; injecting a
    deliberate fleet-identity name mutation reproduces the expected
    mismatch output. Portable across GNU + BSD `find` (no `-printf`).
13. **Drop `Entra AppAdmin` from `fleet-meta`** — ✅ **Done.** Deleted
    `azuread_directory_role_assignment.meta_app_admin` from
    `terraform/bootstrap/fleet/main.identities.tf`; comment rewritten to
    reflect that only `fleet-stage0` holds the role. PLAN §10 identities
    table updated (`fleet-meta` row no longer lists Entra AppAdmin).
14. **Replace `Application Administrator` on `fleet-stage0` with
    `Application.ReadWrite.OwnedBy`** — ✅ **Done.**
    `bootstrap/fleet/main.identities.tf` swaps the
    `azuread_directory_role_assignment` pair for two
    `azuread_app_role_assignment` resources on the Microsoft Graph
    SP: `fleet-stage0` gets `Application.ReadWrite.OwnedBy`
    (owner-scoped CRUD on AAD apps it owns); `fleet-meta` gets
    `AppRoleAssignment.ReadWrite.All` (needed to author per-env
    role assignments from within `bootstrap/environment`).
    `bootstrap/environment` grows its own `azuread` provider and
    a third `azuread_app_role_assignment` granting the same
    `Application.ReadWrite.OwnedBy` to every `uami-fleet-<env>`.
    `stages/0-fleet/main.aad.tf` extends `owners` on both Argo +
    Kargo applications (and their service principals) with the
    stage0 UAMI and every env UAMI, discovered at plan time via
    `data "azuread_service_principal"` keyed off the envs present
    in the cluster inventory (no repo-variable wiring needed).
    `sort(distinct(concat(...)))` keeps owners stable across
    runs. Fixes the latent bug where Stage 1 mgmt Kargo password
    rotation would fail under `fleet-mgmt` on a fresh tenant (the
    mgmt UAMI is now in the Kargo owners list by construction).
    PLAN §10 identities table + relevant prose sweeps updated; F2
    finding deleted from `docs/findings.md` per AGENTS.md
    lifecycle rule.
15. **Stop forced replacement of `stage0_app_admin` directory role
    assignment on every plan** — ✅ **Done.** Superseded by item 14:
    the directory role assignment has been removed entirely in
    favour of the narrower Graph app-role assignment, so the
    template-vs-instance id divergence that drove the churn is
    no longer present in the config.
16. **Document `-var-file` requirement for `bootstrap/fleet`** —
    ✅ **Done.** `bootstrap/fleet` now consumes
    `fleet_runners_app_pem` from the root `.gh-apps.auto.tfvars`
    (F4-class runner-PEM seeding into the fleet KV data plane), but
    `*.auto.tfvars` only auto-loads from the module root being
    applied. `docs/adoption.md §5.1` gains a GH-App PEM prerequisite
    bullet spelling out the explicit
    `-var-file="$(git rev-parse --show-toplevel)/.gh-apps.auto.tfvars"`
    flag and documenting that the root file currently carries 12
    generated GH-App variables (four per App: `*_id`, `*_client_id`,
    `*_pem`, `*_webhook_secret` — see `init-gh-apps.sh:562-578`), so
    passing it to `bootstrap/fleet` produces 11 benign
    `Value for undeclared variable` warnings (everything except
    `fleet_runners_app_pem`, the one field declared in that module).
    Warning-vs-error semantics keep the apply succeeding; the
    residual warnings disappear when PLAN §16.4 grows the Stage-0
    variable blocks + `-var-file` wiring in `tf-apply.yaml`. §5.2
    worked command block updated to include the flag on both the
    first-apply and steady-state invocations. §4 sweep: rewrote the
    stale "`init-gh-apps.sh` seeds the KV via `az keyvault secret
    set`" sentence to match reality (the seeding happens inside
    `bootstrap/fleet` via the `azapi_data_plane_resource` introduced
    by the F4-class work), and clarified that Stage 0's current
    workflow does not yet pass `-var-file` — the file stays at rest
    until §16.4 lands. F5 finding deleted from `docs/findings.md`
    per AGENTS.md lifecycle rule.
