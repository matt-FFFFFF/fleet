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

Last updated: 2026-04-19 · vendored `avm-ptn-cicd-agents-and-runners`
v0.5.2 into `terraform/modules/cicd-runners` (telemetry stripped,
GH-App PEM via KV reference); `bootstrap/fleet` gains a single
repo-scoped self-hosted runner pool (ACA+KEDA), the **fleet Key
Vault** (relocated from Stage 0 to break the runner-pool KV-reference
cycle; private endpoint, deny-default ACLs), and a private endpoint
on the tfstate SA with first-apply-only
`allow_public_state_during_bootstrap` escape hatch; schema and
adoption docs extended accordingly.

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
        escape hatch. Scaffolded; awaits live apply.
  - [~] Self-hosted runner pool (ACA+KEDA, GH App auth via KV ref,
        bring-your-own VNet, per-pool ACR + LAW, no NAT/public IP).
        Scaffolded via `module "runner"` in `main.runner.tf`. First
        job execution awaits operator-supplied PEM via
        `init-gh-apps.sh`.
- [~] `bootstrap/environment/` — scaffolded (state container, env
      UAMI, GH env + variables, observability RG/AG/AMG/AMW/DCE/NSP).
      GH env + UAMI delivered via the vendored
      `modules/github-repo/modules/environment` submodule. Not yet
      applied.
  - [x] yamldecode locals; `var.location` optional.
  - [x] Consumes `fleet_meta_principal_id` input from fleet outputs.
  - [x] OIDC subject claims match fleet (ID-based); FIC name preserved
        via `identity.fic_name = "gh-fleet-<env>"` override.
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

- [x] `docs/adoption.md` — adopter flow.
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
      `tests/unit/fleet_identity.tftest.hcl`.

## Next likely units of work

1. Land `aks-cluster` + `cluster-identities` modules + `stages/1-cluster`.
2. First live apply of `bootstrap/fleet` + `stages/0-fleet` against a real
   tenant; record any drift here.
3. `validate.yaml` + `tf-plan.yaml` CI workflows.
4. CI parity check between `load.sh` naming and bootstrap / Stage 0
   HCL locals.
