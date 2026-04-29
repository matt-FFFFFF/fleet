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
  - [ ] GH Apps manifest-flow helper not written.
- [~] `bootstrap/environment/` — code complete; not applied.
- [~] `bootstrap/team/` — refactored; awaits `team-bootstrap.yaml` CI flow.

### Stage 0 — `terraform/stages/0-fleet`

- [~] Scaffolded; not applied.
  - [x] ACR (Premium, zone-redundant, admin disabled).
  - [x] Fleet Key Vault consumed.
  - [x] Argo AAD application + service principal.
  - [x] Argo RP `client_secret` rotation (60d cadence).
  - [x] Kargo AAD application + service principal.
  - [x] Kargo mgmt UAMI + `AcrPull` on fleet ACR.
  - [x] Redirect URIs derived from cluster inventory.
  - [x] Outputs exported per PLAN §4 Stage 0 table.
  - [x] Fleet ACR private from first apply via `snet-pe-fleet` PE.

### Stage 1 — `terraform/stages/1-cluster`

- [~] Networking slice — code complete; not applied.
  - [x] Identity/RBAC follow-up (cluster KV, UAMIs, role assignments,
        managed Prometheus, mgmt-only Kargo OIDC rotation).
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
- [ ] `stage0-publisher` GitHub App + `init-gh-apps.sh` helper —
      unblocks `publish-stage0` job (currently `if: false`).
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
  - [~] `stages/0-fleet` — not applied.
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
  - [ ] Stage 0 wiring of GH App credentials (TODO).
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
- [x] `allow_public_state_during_bootstrap` first-apply-only variable.
- [x] Terraform floor `~> 1.14` across all first-party modules + CI.
- [x] `main`-branch protection via vendored `modules/ruleset`.

