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
> `[ ]` not started · `[-]` deferred.

## §1 Decisions (locked)

- [x] All Phase-1 decisions captured. No open locks.

## §2 Repository layout

- [x] Top-level scaffold (`clusters/`, `terraform/`, `docs/`, `.github/`).
- [x] `init/` throwaway module + `init-fleet.sh`.
- [ ] `platform-gitops/` — Phase 2+.

## §3 Cluster config schema

- [~] §3.1 `clusters/_fleet.yaml` rendered by `init/`. Fleet identity,
      ACR, state SA, AAD apps, observability, per-`envs` blocks landed;
      networking schema rework (flat `networking.hubs.<env>.regions.<region>`
      map, uniform `networking.envs.<env>.regions.<region>` incl. `mgmt`
      with `mgmt_environment_for_vnet_peering` + `create_reverse_peering`,
      top-level `envs.mgmt.location`, removal of `networking.vnets.mgmt`
      and `fleet.primary_region`) not yet applied to
      `init/templates/_fleet.yaml.tftpl` or `init/variables.tf`.
- [x] `clusters/_defaults.yaml` + env `_defaults.yaml`.
- [x] `clusters/_template/cluster.yaml` onboarding scaffold with
      `networking.subnet_slot` required field.
- [x] §3.2 DNS hierarchy; zone FQDN pattern encoded in `_fleet.yaml`.
- [~] §3.3 Derivation rules in `config-loader/load.sh`:
  - [~] Subscription stitching from `_fleet.yaml.envs.<env>` — loader
        still reads `environments.<env>`; rename pending.
  - [~] Networking derivations (fleet-scope + env-scope in
        `modules/fleet-identity/`; cluster-scope in `load.sh`) — shape
        pre-dates uniform env-region model; rework pending to consume
        new hubs map + mgmt-as-env-region.
  - [ ] Full name-derivation parity with `docs/naming.md` — pending
        audit against bootstrap-stage HCL locals.
- [~] §3.4 Networking topology — spec rewritten to uniform env-region
      model (mgmt is an env; `bootstrap/fleet` owns only fleet-plane
      subnets `snet-pe-fleet` + `snet-runners` on mgmt VNets;
      `bootstrap/environment` owns cluster-workload subnets on every
      env incl. mgmt; UDR route table associated with both api and
      nodes subnets; peering honours per-env-region
      `create_reverse_peering`). Implementation across
      `bootstrap/fleet`, `bootstrap/environment`, `config-loader`,
      `init/`, and Stage 1 DNS-link list pending.
- [x] Example clusters: `mgmt/eastus/aks-mgmt-01`,
      `nonprod/eastus/aks-nonprod-01`.

## §4 Terraform stages

### Stage -1 — `terraform/bootstrap/`

- [~] `bootstrap/fleet/` — scaffolded (state SA, stage0 + meta UAMIs,
      FICs, GH repo + `main`-branch ruleset, env variables, private
      tfstate SA endpoint, self-hosted runner pool, fleet KV with PE,
      mgmt VNet + subnets + NSGs + hub peering, `Network Contributor`
      on mgmt VNet → `fleet-meta`, `MGMT_VNET_RESOURCE_ID` published
      to the `fleet-meta` GH Environment). Delivered via vendored
      `terraform/modules/github-repo` and `terraform/modules/cicd-runners`.
      **Not yet applied against a live tenant.** Pending PLAN
      realignment: rework to create one mgmt env-region VNet shell per
      `networking.envs.mgmt.regions.<region>`, own only fleet-plane
      subnets (`snet-pe-fleet` + `snet-runners` /23 ACA-delegated),
      drop fleet-scope `MGMT_VNET_RESOURCE_ID` in favour of uniform
      `MGMT_<REGION>_{VNET_RESOURCE_ID,PE_FLEET_SUBNET_ID,RUNNERS_SUBNET_ID}`.
  - [ ] GH Apps (`fleet-meta`, `stage0-publisher`, `fleet-runners`) —
        documented as TODO in `main.github.tf`; manifest-flow helper
        not written.
- [~] `bootstrap/environment/` — scaffolded (env state container,
      env UAMI, GH env + variables, observability stack, env VNets +
      intra-env mesh + hub peering + per-region NSG/ASG + mgmt↔env
      peerings with reverse half, Grafana PE on derived subnet,
      per-region `<ENV>_<REGION>_*` repo-env vars). **Not yet
      applied.** Pending PLAN realignment: run uniformly for every
      env incl. `mgmt` (for `mgmt` references pre-existing VNet
      shell and carves cluster-workload subnets as azapi children);
      own `snet-pe-env` on every env-region VNet (hosts mgmt cluster
      KV PE on mgmt); route table associated with both api and
      nodes subnets; honour per-env-region `create_reverse_peering`
      toggle on mgmt↔spoke peering.
- [~] `bootstrap/team/` — refactored onto the vendored module;
      awaits `team-bootstrap.yaml` CI flow.

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
  - [ ] Fleet ACR private endpoint rewire to derived `snet-pe-shared`
        + central `privatelink.azurecr.io` zone.

### Stage 1 — `terraform/stages/1-cluster`

- [~] Networking slice landed: root scaffolding, per-cluster `/28` api
      + `/25` nodes subnets as azapi children of the env-region VNet,
      AVM AKS wrapper with curated `cluster.aks.*` passthrough,
      per-cluster private DNS zone + VNet links to env-region VNet +
      mgmt env-region VNet in same region (mgmt clusters collapse to
      single link), node pool attachment to env-region ASG. Pending
      realignment: drop fleet-scope `MGMT_VNET_RESOURCE_ID`
      consumption in favour of uniform
      `MGMT_<REGION>_VNET_RESOURCE_ID` lookup.
  - [ ] Identity/RBAC follow-up: cluster KV, UAMIs (external-dns,
        ESO, per-team), role assignments (AcrPull on kubelet, RBAC
        Cluster Admin for `fleet-<env>` + AAD groups, RBAC Reader
        for Kargo mgmt, Private DNS Zone Contributor, Monitoring
        Metrics Publisher), managed Prometheus DCR/DCRA + rules,
        Kargo mgmt OIDC secret rotation.
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
      and `modules/fleet-identity/tests/unit/`.

## §11 Operator UX

- [x] `docs/adoption.md`.
- [x] `docs/networking.md`.
- [x] `docs/onboarding-cluster.md`.
- [ ] `onboarding-team.md`, `upgrades.md`, `promotion.md`.

## §12 Risks and mitigations

- Reference-only.

## §13 Phased implementation

- [~] **Phase 1 (Skeleton)** — in progress:
  - [x] Repo scaffold per §2.
  - [x] `_fleet.yaml` (generated) + `_defaults.yaml`.
  - [~] `bootstrap/fleet` code; not applied.
  - [~] `bootstrap/environment` code; not applied.
  - [~] `stages/0-fleet` body; not applied.
  - [~] `stages/1-cluster` — networking slice landed; identity/RBAC
        surface pending.
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

- Reference-only.

## §15 Remaining open items (deferred)

- Reference-only.

## §16 Template-repo adoption model

- [x] §16.1 Single source of truth (`clusters/_fleet.yaml` generated).
- [x] §16.2 Bootstrap TF reads yaml (both stacks refactored).
- [x] §16.3 `init-fleet.sh` wrapper over `init/` TF module.
- [x] §16.4 `init-gh-apps.sh` — manifest flow for `fleet-meta` /
      `stage0-publisher` / `fleet-runners` Apps; writes
      `./.gh-apps.state.json` + `./.gh-apps.auto.tfvars`; patches
      `_fleet.yaml` with runner IDs; self-deletes. Stage 0 wiring of
      the tfvars overlay remains TODO.
- [x] §16.5 GitHub template mechanics; `import` block for fleet repo.
- [x] §16.6 `docs/naming.md`.
  - [ ] CI diff between `load.sh` and bootstrap HCL locals — deferred.
- [x] §16.7 Safety rails (banner, dirty-tree refusal, TF validation).
- [x] §16.8 Template self-test workflow.
- [~] §16.9 File additions/modifications landed for prior schema;
      rework pending to land uniform env-region networking schema
      (`envs` rename, `networking.hubs` map, `envs.mgmt.location`,
      per-env-region `create_reverse_peering`,
      `mgmt_environment_for_vnet_peering`) in
      `init/templates/_fleet.yaml.tftpl` + `init/variables.tf`
      + `config-loader/load.sh` + `modules/fleet-identity/`.
- [x] §16.10.1–9 Execution order complete.
  - [-] §16.10.10 CI naming-diff — deferred to Phase 2 CI work.

---

## Outside-PLAN scaffolding

- [x] `.fleet-initialized` marker contract.
- [x] `.github/fixtures/adopter-test.tfvars` selftest input.
- [x] `AGENTS.md` — agent onboarding preamble.
- [x] `terraform/modules/github-repo/` vendored fork. See
      `VENDORING.md` for upstream diff.
- [x] `terraform/modules/cicd-runners/` vendored fork. See
      `VENDORING.md` for upstream diff.
- [x] `terraform/modules/fleet-identity/` pure-function derivation
      module (names + networking identifiers + GH-App coordinates
      from parsed `_fleet.yaml`); consumed by both `bootstrap/fleet`
      and `bootstrap/environment`.
- [x] `allow_public_state_during_bootstrap` first-apply-only variable
      on `bootstrap/fleet` (tfstate SA public toggle).
- [x] Terraform floor `~> 1.14` across all first-party modules + CI;
      exact version pinned in `.terraform-version`.
- [x] `main`-branch protection via vendored `modules/ruleset`
      (Kargo-bot bypass deferred per §10 / §15).

## Next likely units of work

1. Land uniform env-region networking schema per PLAN §3.1/§3.4 rework:
   `init/templates/_fleet.yaml.tftpl` + `init/variables.tf`,
   `config-loader/load.sh` (envs rename, hubs map, mgmt-as-env-region),
   `modules/fleet-identity/` derivations, `bootstrap/fleet` (mgmt VNet
   shells + fleet-plane subnets only), `bootstrap/environment`
   (cluster-workload subnets on every env incl. mgmt; per-env-region
   `create_reverse_peering`), Stage 1 DNS-link list.
2. Route-table + node-subnet + api-subnet association so UDR egress
   apply works against a live tenant.
3. Stage 1 identity/RBAC follow-up (cluster KV, UAMIs, role
   assignments, managed Prometheus, Kargo mgmt rotation).
4. First live apply of `bootstrap/fleet` + `stages/0-fleet` against
   a real tenant.
5. `validate.yaml` + `tf-plan.yaml` + `tf-apply.yaml` CI workflows.
6. CI parity check between `load.sh` naming and bootstrap / Stage 0
   HCL locals.
