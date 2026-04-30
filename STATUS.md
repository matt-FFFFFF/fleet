# STATUS

> **What this is.** A one-line-per-sub-item index mirroring
> `PLAN.md`'s section numbers. `PLAN.md` answers "what should be";
> this file answers "what is." Section numbers match `PLAN.md`.
>
> **Discipline.** Routine file-level edits, refactors, and
> in-progress commits do not appear here. Update only when a PLAN
> sub-item's state changes. If in doubt, it doesn't belong.
> Completed items need no accompanying text — that lives in PLAN.
> Partial items get a brief note only.
>
> Legend: `[x]` done · `[~]` in progress / scaffolded but unapplied
> `[!]` **rework required** · `[ ]` not started · `[-]` deferred.

## §1 Decisions (locked)

- [x] All Phase-1 decisions captured.

## §2 Repository layout

- [x] Top-level scaffold (`clusters/`, `terraform/`, `docs/`, `.github/`).
- [x] `init/` throwaway module + `init-fleet.sh`.
- [ ] `platform-gitops/` — Phase 2+.

## §3 Cluster config schema

- [~] §3.1 `clusters/_fleet.yaml` rendered by `init/` — renderer done;
      end-to-end adoption flow blocked on live apply.
- [x] `clusters/_defaults.yaml` + env `_defaults.yaml`.
- [x] `clusters/_template/cluster.yaml` onboarding scaffold.
- [x] §3.2 DNS hierarchy.
- [x] §3.3 Derivation rules — loader + `modules/fleet-identity/` parity established.
- [x] §3.4 Networking topology.
- [x] Example clusters: `mgmt/eastus/aks-mgmt-01`, `nonprod/eastus/aks-nonprod-01`.

## §4 Terraform stages

### Stage -1 — `terraform/bootstrap/`

- [~] `bootstrap/fleet/` — code complete; not applied.
  - [x] **Refactor**: rename fleet KV → runner-pool KV
        (`kv-<fleet>-runners` in `rg-fleet-runners`); drop all secrets
        except `fleet-runners-app-pem` and `fleet-meta-app-pem`.
  - [x] **Refactor**: drop `stage0-publisher` GH App + `fleet-stage0`
        environment + `uami-fleet-stage0` + Graph
        `Application.ReadWrite.OwnedBy` grant; `azuread` provider
        removed.
  - [x] **Refactor (Step 4 revert)**: own Argo + Kargo AAD apps +
        SPs + 2-year RP `client_secret` values; publish
        `ARGO_AAD_APP_ID` / `KARGO_AAD_APP_ID` /
        `KARGO_AAD_APPLICATION_OBJECT_ID` repo-level vars; gate
        mgmt-cluster KV writes on `var.mgmt_cluster_kv_id` (two-pass
        apply per docs/adoption.md §5.3). `azuread` provider
        re-added.
  - [~] **Deferral (PLAN §15)**: runner pool ships with
        `use_private_networking = false` because the vendored
        `cicd-runners` module silently disables LAW public ingestion
        + query when private networking is on but authors no
        AMPLS/NSP path. Re-enable contract is documented in the
        callsite comment block + the §15 NSP recommendation. ACR public,
        ACA platform-managed VNet, LAW public ingestion until §15
        closes.
- [~] `bootstrap/environment/` — code complete; not applied.
  - [~] **Refactor**: env=mgmt absorbs fleet ACR + PE +
        `length(mgmt_clusters) == 1` precondition; publishes
        `ACR_*` repo-level vars; drops `fleet_kv_secrets_user`.
        Steps 1+3 done (ACR absorbed; `fleet_kv_secrets_user` removed);
        `length == 1` precondition + `ACR_*` repo-level publishes
        pending.
  - [x] env=mgmt grants `uami-fleet-mgmt` `Key Vault Secrets User`
        on the runners KV so the `tf-apply.yaml` mgmt-publish step
        (`az keyvault secret show fleet-meta-app-pem` →
        `actions/create-github-app-token` → `MGMT_*` repo-var upsert)
        can read the PEM. Required because the runners KV uses RBAC
        authorization (no transitive access from subscription
        Contributor).
- [~] `bootstrap/team/` — refactored; awaits `team-bootstrap.yaml` CI flow.

### Stage 1 — `terraform/stages/1-cluster`

- [~] Networking slice — code complete; not applied.
  - [x] Identity/RBAC follow-up (cluster KV, UAMIs, role assignments,
        managed Prometheus).
  - [x] **Refactor**: mgmt cluster Stage 1 owns `uami-kargo-mgmt` +
        AcrPull and publishes `MGMT_CLUSTER_KV_ID` / `KARGO_MGMT_UAMI_*` /
        `MGMT_AKS_*` repo vars (via `tf-apply.yaml` post-apply step
        gated on `matrix.cluster.role == 'management'`). Argo + Kargo
        AAD apps + RP secrets moved to `bootstrap/fleet` (operator-
        applied; PLAN §4 Stage -1) — Stage 1 mgmt no longer touches
        Microsoft Graph.
  - [~] **Refactor**: spoke `ra_eso_fleet_kv` →
        `ra_eso_mgmt_cluster_kv` (consumes `mgmt_cluster_kv_id`).
        Done (Step 4c).
- [x] Pod CIDR / service CIDR fleet-wide constants in `modules/aks-cluster`.
- [x] `validate.yaml` subnet_slot PR-check.
- [x] `tf-apply.yaml` workflow.

### Stage 2 — `terraform/stages/2-kubernetes`

- [ ] Not started (Phase 2).
- [ ] `terraform/modules/argocd-bootstrap` — not written.

## §5 ArgoCD + Kargo bootstrap sequence

- [ ] Phase 2.

## §6 Platform promotion model (Kargo)

- [ ] Phase 4–5.

## §7 Team tenancy

- [ ] Phase 6.

## §8 Secrets & identity

- [~] Design locked; ESO + KV wiring pending Stage 2.

## §9 RBAC

- [x] Design locked; per-env group bindings expressed as empty `[]`
      with `TODO` comments.

## §10 CI/CD

- [x] `validate.yaml` — fmt, tflint, yamllint, subnet-slot, naming-parity.
- [x] `tf-plan.yaml`.
- [x] `tf-apply.yaml`.
- [x] `env-bootstrap.yaml`.
- [x] `team-bootstrap.yaml`.
- [x] `.github/scripts/detect-affected-clusters.sh`.
- [x] `template-selftest.yaml` (template-side only).
- [x] `status-check.yaml` (template-side only).
- [-] `tflint.yaml` — folded into `validate.yaml`.
- [x] `terraform test` unit suites.

### §10 deferred

- [ ] JSON-schema validation of merged `cluster.yaml` + team YAMLs.
- [ ] `lint-teams.sh` team-config linter.
- [ ] `helm lint` over `platform-gitops/components/*`.
- [ ] `kargo lint` over `platform-gitops/kargo/**`.
- [ ] `terraform/stages/2-kubernetes/` module — unblocks Stage 2 plan/apply.
- [ ] Nightly drift-detection workflow.

## §11 Operator UX

- [x] `docs/adoption.md`.
- [x] `docs/networking.md`.
- [x] `docs/onboarding-cluster.md`.
- [x] `docs/naming.md`.
- [ ] `onboarding-team.md`, `upgrades.md`, `promotion.md`.

## §12 Risks and mitigations

- Reference-only.

## §13 Phased implementation

- [~] **Phase 1 (Skeleton)** — code complete; blocked on live apply.
  - [x] Repo scaffold per §2.
  - [~] `_fleet.yaml` + `_defaults.yaml`.
  - [~] `bootstrap/fleet` — not applied.
  - [~] `bootstrap/environment` — not applied.
  - [~] `stages/1-cluster` — not applied.
  - [x] `config-loader/load.sh` naming-derivation parity CI diff.
  - [x] CI workflows.
  - [ ] **Exit criterion** — blocked on live apply.
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
- [x] §16.2 Bootstrap TF reads yaml.
- [x] §16.3 `init-fleet.sh` wrapper over `init/` TF module.
- [x] §16.4 `init-gh-apps.sh` — manifest flow.
  - [x] `fleet-meta` GH App provisioning + KV PEM seeding.
  - [x] `fleet-runners` GH App provisioning + KV PEM seeding.
- [x] §16.5 GitHub template mechanics; `import` block for fleet repo.
- [x] §16.6 `docs/naming.md`.
  - [x] CI diff between `load.sh` and bootstrap HCL locals.
- [x] §16.7 Safety rails (banner, dirty-tree refusal, TF validation).
- [x] §16.8 Template self-test workflow.
- [x] §16.9 File additions/modifications.
- [x] §16.10.1–9 Execution order complete.
  - [x] §16.10.10 CI naming-diff.

---

## Outside-PLAN scaffolding

- [x] `.fleet-initialized` marker contract.
- [x] `.github/fixtures/adopter-test.tfvars` selftest input.
- [x] `AGENTS.md` — agent onboarding preamble.
- [x] `terraform/modules/github-repo/` vendored fork.
- [x] `terraform/modules/cicd-runners/` vendored fork.
- [x] `terraform/modules/fleet-identity/` pure-function derivation module.
- [x] Terraform floor `~> 1.14` across all first-party modules + CI.
- [x] `main`-branch protection via vendored `modules/ruleset`.

