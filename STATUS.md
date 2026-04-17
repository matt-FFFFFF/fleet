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

Last updated: 2026-04-17 · stages/0-fleet scaffolded (ACR, fleet KV,
AAD apps, Argo RP secret rotation, Kargo mgmt UAMI).

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
      state SA, AAD apps, observability, per-env blocks.
- [x] `clusters/_defaults.yaml` + env `_defaults.yaml` (mgmt has
      node_pools override; nonprod/prod are `{}`).
- [x] `clusters/_template/cluster.yaml` onboarding scaffold.
- [x] §3.2 DNS hierarchy documented; zone FQDN pattern encoded in
      `_fleet.yaml`.
- [~] §3.3 Derivation rules in `config-loader/load.sh`:
  - [x] Subscription stitching from `_fleet.yaml.environments.<env>`.
  - [ ] Full name-derivation parity with `docs/naming.md` — pending
        audit against bootstrap-stage HCL locals.
- [x] Example clusters: `mgmt/eastus/aks-mgmt-01`,
      `nonprod/eastus/aks-nonprod-01` (referenced; content unchanged
      since initial scaffold).

## §4 Terraform stages

### Stage -1 — `terraform/bootstrap/`

- [~] `bootstrap/fleet/` — scaffolded (state SA, stage0 + meta UAMIs,
      FICs, GH repo + branch protection, env variables). **Not yet
      applied against a live tenant.**
  - [x] yamldecode locals; no `var.fleet`.
  - [x] `import` block for `github_repository.fleet`.
  - [ ] GH Apps (`fleet-meta`, `stage0-publisher`) — documented as
        TODO in `main.github.tf`; manifest-flow helper not written.
  - [ ] PEMs → fleet KV wiring (deferred; KV created in Stage 0).
- [~] `bootstrap/environment/` — scaffolded (state container, env
      UAMI, GH env + variables, observability RG/AG/AMG/AMW/DCE/NSP).
      Not yet applied.
  - [x] yamldecode locals; `var.location` optional.
  - [x] Consumes `fleet_meta_principal_id` input from fleet outputs.
- [ ] `bootstrap/team/` — stub only; awaits PLAN §4 Stage -1
      `team-bootstrap.yaml` flow.

### Stage 0 — `terraform/stages/0-fleet`

- [~] Scaffolded; **not yet applied**:
  - [x] ACR (Premium, zone-redundant, admin disabled).
  - [x] Fleet Key Vault (RBAC-auth, purge protection, soft-delete 90d).
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

### Stage 1 — `terraform/stages/1-cluster`

- [ ] Stage body not written.
- [~] `terraform/modules/aks-cluster` — AVM wrapper pending detail.
- [x] `terraform/modules/cluster-dns` — present (zone + links + role
      assignment).
- [ ] `terraform/modules/cluster-identities` — not written.

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

- [x] Design locked; per-env group bindings expressed as `<…>`
      placeholders in rendered `_fleet.yaml` for post-init fill-in.

## §10 CI/CD

- [ ] `validate.yaml`, `tf-plan.yaml`, `tf-apply.yaml`,
      `env-bootstrap.yaml`, `team-bootstrap.yaml` — not yet written.
- [x] `.github/workflows/template-selftest.yaml` — implemented
      (template-side only; removed by `init-fleet.sh` for adopters).
- [x] `.github/workflows/status-check.yaml` — enforces STATUS
      discipline on PRs touching tracked paths (template-side only;
      removed by `init-fleet.sh` for adopters).
- [x] `.github/workflows/tflint.yaml` + `.tflint.hcl` — recursive
      tflint on every PR; `terraform_unused_declarations` and
      `terraform_naming_convention` enforced. Kept in adopter repos.

## §11 Operator UX

- [x] `docs/adoption.md` — adopter flow.
- [ ] `docs/onboarding-cluster.md`, `onboarding-team.md`,
      `upgrades.md`, `promotion.md` — stubs / not written.

## §12 Risks and mitigations

- Reference-only; no work items.

## §13 Phased implementation

- [~] **Phase 1 (Skeleton)** — in progress:
  - [x] Repo scaffold per §2.
  - [x] `_fleet.yaml` (generated) + `_defaults.yaml`.
  - [x] `bootstrap/fleet` code; not applied.
  - [x] `bootstrap/environment` code; not applied.
  - [x] `stages/0-fleet` body — scaffolded, not applied.
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
- [x] §16.3 `init-fleet.sh` wrapper over `init/` TF module.
- [x] §16.4 GitHub template mechanics; `import` block for fleet repo.
- [x] §16.5 `docs/naming.md` drafted.
  - [ ] CI diff between `load.sh` and bootstrap HCL locals — deferred.
- [x] §16.6 Safety rails (banner, dirty-tree refusal, TF validation).
- [x] §16.7 Template self-test workflow.
- [x] §16.8 All file additions/modifications landed.
- [x] §16.9.1–9 Execution order complete.
  - [-] §16.9.10 CI naming-diff — deferred to Phase 2 CI work.

---

## Outside-PLAN scaffolding

- [x] `.fleet-initialized` marker contract (written by `init/`,
      committed, checked by `init-fleet.sh --force`).
- [x] `.github/fixtures/adopter-test.tfvars` selftest input.
- [x] `AGENTS.md` — agent onboarding preamble.

## Next likely units of work

1. Land `aks-cluster` + `cluster-identities` modules + `stages/1-cluster`.
2. First live apply of `bootstrap/fleet` + `stages/0-fleet` against a real
   tenant; record any drift here.
3. `validate.yaml` + `tf-plan.yaml` CI workflows.
4. CI parity check between `load.sh` naming and bootstrap / Stage 0
   HCL locals.
