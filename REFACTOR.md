# Stage 0 elimination + fleet KV rename

Cross-cutting refactor that removes `terraform/stages/0-fleet`, redistributes
its contents to the layers that actually own them, and renames the
`fleet KV` to reflect its post-refactor role as the runner-pool's KV.

This file is a **scratch plan**, not a permanent design document. Delete it
once the refactor lands and PLAN.md / STATUS.md / docs/ have absorbed the
intent.

## Motivation

`bootstrap/environment` (env=mgmt) needs to grant `uami-fleet-mgmt` the
ACR UAccessAdmin role at the fleet ACR's scope. Stage 0 owns the fleet ACR
and is itself blocked on `data.azuread_service_principal.mgmt_uami` —
which `bootstrap/environment` env=mgmt is the only thing that creates.
Apply-time circular dependency.

Reviewing Stage 0's contents revealed that none of them actually require
their own stage:

| Stage 0 today                                         | Real owner |
|-------------------------------------------------------|------------|
| Fleet ACR + PE + DNS zone group                       | `bootstrap/environment` env=mgmt (mgmt-tenanted infra; mgmt is now a fleet-wide singleton) |
| Argo AAD app + service principal + RP secret          | `bootstrap/fleet` (operator-owned; least Stage 1 blast radius) |
| Kargo AAD app + service principal + RP secret         | `bootstrap/fleet` (same) |
| `uami-kargo-mgmt` + AcrPull on fleet ACR              | Stage 1 mgmt (workload identity, mgmt-only; FIC already lives in Stage 2 mgmt) |
| KV Secrets Officer for stage0 identity                | Deleted (no Stage 0 identity exists post-refactor) |
| `argocd-oidc-client-secret` rotation target           | Mgmt cluster KV — written by `bootstrap/fleet` once mgmt KV exists |
| `mgmt_clusters` enumeration / validation              | `bootstrap/environment` env=mgmt (precondition `length == 1`) |

Independently: the **fleet KV** was sized "fleet-wide" but actually holds
only secrets used to bootstrap the runner pool + envs (`fleet-runners-app-pem`,
`fleet-meta-app-pem`) plus the Argo OIDC RP secret (which moves to mgmt
cluster KV with the AAD app). After the refactor it's just the
runner-pool's KV. Rename to reflect ownership.

## Architectural changes (PLAN updates required)

1. **Hard limit: exactly one mgmt cluster per fleet.** Enforced as a
   `length(mgmt_clusters) == 1` precondition in `bootstrap/environment`
   env=mgmt. Codifies what PLAN §1 already implies for hub-and-spoke
   Argo. Documented in PLAN §1 + §4.

2. **Stage 0 deleted.** PLAN §4 stage list collapses to: Stage -1
   (`bootstrap/fleet`) → `bootstrap/environment` (per env) →
   `bootstrap/team` (per team) → Stage 1 (per cluster) → Stage 2 (per
   cluster). PLAN §16 implementation status callouts updated. PLAN §13
   role-assignment matrix loses the Stage 0 column.

3. **Fleet ACR moves to `bootstrap/environment` env=mgmt.** Naming
   derivation (`docs/naming.md`, `config-loader/load.sh`,
   `modules/fleet-identity/main.tf`) unchanged — derivation key stays
   `acr_*`, just the creating stage changes. Repo-var publishes
   (`ACR_RESOURCE_ID`, `ACR_NAME`, `ACR_LOGIN_SERVER`) move from Stage
   0 outputs → `bootstrap/environment` env=mgmt repo-level vars.

4. **Argo + Kargo AAD apps move to `bootstrap/fleet`** (NOT Stage 1
   mgmt). Operator-applied locally via `az login` with Global Admin
   credentials, so no Graph permission grants on any UAMI are
   required. Apps are fleet singletons with stable lifecycle; this
   keeps them outside per-cluster apply blast radius (Stage 1 mgmt
   has no `azuread_*` resources). Long-lived (2-year) RP
   `client_secret` per app, written into the mgmt cluster KV once
   it exists. Repo-var publishes (`ARGO_AAD_APP_ID`,
   `KARGO_AAD_APP_ID`, `KARGO_AAD_APPLICATION_OBJECT_ID`) move from
   Stage 0 → `bootstrap/fleet` repo-level vars (via the existing
   `github` provider). Stage 1 mgmt continues to publish
   `MGMT_CLUSTER_KV_ID`, `KARGO_MGMT_UAMI_*`, `MGMT_AKS_*` repo vars
   as those depend on Stage 1-owned resources.

5. **`uami-kargo-mgmt` moves to Stage 1 mgmt.** AcrPull on fleet ACR
   stays — same scope, different stage. FIC binding the UAMI to the
   Kargo controller SA already lives in Stage 2 mgmt; unchanged.

6. **Argo + Kargo OIDC RP secrets written into the mgmt cluster KV
   by `bootstrap/fleet`.** `bootstrap/fleet`'s `azapi_resource`s
   target the mgmt cluster KV via `var.mgmt_cluster_kv_id`
   (defaults `null`; `count` gates the writes when null). First
   `bootstrap/fleet` apply creates Apps + passwords but skips the KV
   writes. Stage 1 mgmt apply creates the mgmt KV and publishes
   `MGMT_CLUSTER_KV_ID` repo var. Operator re-runs `bootstrap/fleet`
   apply with `MGMT_CLUSTER_KV_ID` populated; secrets land. ESO on
   every cluster (mgmt + spokes) reads them from the mgmt cluster
   KV — unchanged. Spoke Stage 1's `ra_eso_fleet_kv` becomes
   `ra_eso_mgmt_cluster_kv`, scoped to the mgmt cluster KV's
   resource id.

7. **Fleet KV renamed → runner-pool KV; reparented to
   `rg-fleet-runners`.** Naming derivation key
   `fleet_kv_*` → `runners_kv_*`. Holds:
   - `fleet-runners-app-pem` (consumed by KEDA runner pool)
   - `fleet-meta-app-pem` (consumed by env-bootstrap.yaml + team-bootstrap.yaml)

   Both UAMIs (`uami-fleet-runners`, `uami-fleet-meta`) get
   `Key Vault Secrets User` at vault scope, granted by `bootstrap/fleet`.
   Optional ABAC tightening to scope each UAMI to its own secret name —
   defer unless trivial.

8. **`bootstrap/environment` `fleet_kv_secrets_user` env grant deleted.**
   No more fleet KV; per-env UAMIs don't read from the runner-pool KV.

9. **`docs/adoption.md` ordering simplifies.** Stage 0 references
   removed. The previously documented §5.3 manual Graph grant on
   `uami-fleet-mgmt` (`Application.ReadWrite.OwnedBy`) is also
   removed — no UAMI carries Graph perms post-refactor; AAD app
   lifecycle is operator-driven from `bootstrap/fleet`. Two-pass
   `bootstrap/fleet` apply documented (first pass before mgmt
   cluster, second pass after mgmt KV exists).

## Renames

| Old key / name                       | New key / name                      | Touchpoints |
|--------------------------------------|-------------------------------------|-------------|
| `local.derived.fleet_kv_name`        | `local.derived.runners_kv_name`     | `modules/fleet-identity/main.tf`, `config-loader/load.sh`, `docs/naming.md`, `bootstrap/fleet`, `init-gh-apps.sh` |
| `local.derived.fleet_kv_resource_group` | `local.derived.runners_kv_resource_group` | same |
| `local.derived.fleet_kv_location`    | `local.derived.runners_kv_location` | same |
| `_fleet.yaml.keyvault.*`             | `_fleet.yaml.runners_keyvault.*`    | `init/templates/_fleet.yaml.tftpl`, `init/variables.tf`, `init-gh-apps.sh` patcher |
| `azapi_resource.fleet_kv` (TF)       | `azapi_resource.runners_kv`         | `bootstrap/fleet/main.kv.tf` |
| Output `fleet_kv_id` / `fleet_kv_vault_uri` | `runners_kv_id` / `runners_kv_vault_uri` | `bootstrap/fleet/outputs.tf` |
| Repo var `FLEET_KV_NAME`             | `RUNNERS_KV_NAME`                   | `bootstrap/fleet/main.github.tf`, env-bootstrap.yaml, team-bootstrap.yaml |
| KV secret name `fleet-runners-app-pem` | unchanged (semantic name, not derivation) | — |
| KV secret name `fleet-meta-app-pem`  | unchanged | — |

The actual KV resource name in Azure changes:
`kv-<fleet>-fleet` → `kv-<fleet>-runners` (24-char trim still applies).

## Refactor sequence

Each step is a separable working state; commit per step, but ship as a
single PR against adopter `main` (multi-file move; intermediate states
break things).

### Step 1 — Move fleet ACR to `bootstrap/environment` env=mgmt

- Create `terraform/bootstrap/environment/main.acr.tf` (mgmt-only,
  `count = var.env == "mgmt" ? 1 : 0`):
  - `azapi_resource.fleet_acr` (verbatim copy from
    `stages/0-fleet/main.acr.tf`)
  - `azapi_resource.fleet_acr_pe` + DNS zone group
  - Preconditions on `mgmt_pe_fleet_subnet_ids` + `pdz_azurecr`
- Add `length(mgmt_clusters) == 1` precondition (use a
  `terraform_data` resource so the error fires before any apply work).
- Publish repo-level vars (NOT environment vars):
  `ACR_RESOURCE_ID`, `ACR_NAME`, `ACR_LOGIN_SERVER`. Use
  `github_actions_variable` (repo-level) gated on env=mgmt.
- `bootstrap/environment/main.github.tf`'s `acr_uaa_bounded` role
  assignment now references the same-stage ACR resource directly when
  env=mgmt; for non-mgmt envs it references `local.fleet_acr_id`
  (synthesized ARM id) which by step 5 will resolve to a real existing
  ACR.

### Step 2 — Rename fleet KV → runner-pool KV in source

Pure mechanical rename, no resource moves yet. Tests should still pass.

- `modules/fleet-identity/main.tf`: rename derived locals.
- `terraform/config-loader/load.sh`: rename mapped keys (matches HCL
  derivation per AGENTS.md §5).
- `docs/naming.md`: rename + bump example.
- `init/templates/_fleet.yaml.tftpl`: rename top-level
  `keyvault:` block → `runners_keyvault:`.
- `init/variables.tf`: rename `pdz_vaultcore` description.
- `init-gh-apps.sh`: rename `_fleet.yaml.keyvault.*` reads.
- `bootstrap/fleet/main.kv.tf`: rename HCL resources (`fleet_kv` →
  `runners_kv`); add `moved {}` blocks so existing state migrates
  without recreate.
- `bootstrap/fleet/main.runner.tf`: update KV-reference URI.
- `bootstrap/fleet/outputs.tf`: rename outputs.
- `bootstrap/fleet/main.github.tf`: `FLEET_KV_NAME` → `RUNNERS_KV_NAME`
  on `meta_env_vars`.
- `.github/workflows/env-bootstrap.yaml`,
  `.github/workflows/team-bootstrap.yaml`: rename
  `vars.FLEET_KV_NAME` → `vars.RUNNERS_KV_NAME`.

### Step 3 — Reparent runner-pool KV to `rg-fleet-runners`

The KV's `parent_id` changes from `rg-fleet-shared` to
`rg-fleet-runners`. No live adopter state to migrate (scopfleet is
restarting from zero), so this is a clean source-only edit:

- `bootstrap/fleet/main.kv.tf`: KV `parent_id` → `rg-fleet-runners`.
- KV's PE subnet stays `snet-pe-fleet` (mgmt env, swedencentral) —
  the runner pool consumes the KV from `rg-fleet-runners` but its
  PE lives in mgmt's PE subnet, same as today.
- DNS zone group unchanged (`privatelink.vaultcore.azure.net`).

### Step 4 — Move Argo / Kargo AAD apps to `bootstrap/fleet`

NOTE: this step replaces an earlier draft of REFACTOR.md that
co-located the apps in Stage 1 mgmt. That draft was reverted because
it forced Stage 1's `uami-fleet-mgmt` to carry Microsoft Graph
`Application.ReadWrite.OwnedBy` and authored AAD apps on every cluster
PR plan — both unwanted (operator-driven AAD lifecycle, narrow blast
radius). Step 4 below is the replacement direction.

- `terraform/bootstrap/fleet/main.aad.tf` (new):
  - `azuread_application.argocd` + `azuread_service_principal.argocd`
    — single-tenant, mgmt-cluster-local redirect URI derived from
    `_fleet.yaml.dns.fleet_root` + the mgmt cluster's
    `cluster.{name,region,env}` (resolved by reading `mgmt_clusters`
    out of `_fleet.yaml`'s adjacent `clusters/` tree — same pattern
    as `bootstrap/environment` env=mgmt).
  - `azuread_application_password.argocd` — `end_date` set to
    `now + 2y`. No `time_rotating`. Re-rolled by operator (taint or
    new resource) when needed.
  - `azuread_application.kargo` + `azuread_service_principal.kargo`
    + `azuread_application_password.kargo` — same shape.
  - `azapi_resource.argocd_oidc_secret` writing
    `argocd-oidc-client-secret` to mgmt cluster KV; gated
    `count = var.mgmt_cluster_kv_id != null ? 1 : 0`.
  - `azapi_resource.kargo_oidc_secret` writing
    `kargo-oidc-client-secret` to mgmt cluster KV; same gate.
  - `github_actions_variable` repo-level vars: `ARGO_AAD_APP_ID`,
    `KARGO_AAD_APP_ID`, `KARGO_AAD_APPLICATION_OBJECT_ID`.
- `terraform/bootstrap/fleet/variables.tf`: add `var.mgmt_cluster_kv_id`
  (default `null`).
- `terraform/bootstrap/fleet/providers.tf`: re-introduce
  `hashicorp/azuread ~> 3.0` provider. Operator-context auth
  (`use_cli = true`).
- `terraform/stages/1-cluster/main.aad.argocd.tf`: DELETE.
- `terraform/stages/1-cluster/main.aad.kargo.tf`: DELETE.
- `terraform/stages/1-cluster/main.kv.tf`: strip the Kargo RP-secret
  rotation block (`time_rotating.kargo_oidc_secret`,
  `azuread_application_password.kargo_oidc_secret`,
  `azapi_resource.kargo_oidc_secret`). The cluster KV module call
  remains unchanged.
- `terraform/stages/1-cluster/providers.tf`: drop `azuread` +
  `time` providers (no longer used by Stage 1).
- `terraform/stages/1-cluster/main.identities.kargo.tf` (uami-kargo-mgmt
  + AcrPull): UNCHANGED — workload identity, distinct from the AAD
  app, stays in Stage 1 mgmt.
- Spoke Stage 1's `ra_eso_mgmt_cluster_kv` (REFACTOR.md Step 4c earlier
  commit): UNCHANGED — mgmt cluster KV is still the destination, only
  the writer changes.
- `terraform/stages/1-cluster/outputs.tf`: drop
  `argocd_aad_application_id`, `kargo_aad_application_id`,
  `kargo_aad_application_object_id`. Keep `kargo_mgmt_uami_*` and
  `mgmt_cluster_keyvault_id` (Stage 1 mgmt still owns those).
- `.github/workflows/tf-apply.yaml` mgmt-publish step: drop
  `ARGO_AAD_APP_ID`, `KARGO_AAD_APP_ID`,
  `KARGO_AAD_APPLICATION_OBJECT_ID` upserts (now published by
  bootstrap/fleet via Terraform).

### Step 5 — Delete Stage 0

- `rm -rf terraform/stages/0-fleet/`.
- `.github/workflows/stage0.yaml` (if it exists as a separate
  workflow) — delete.
- `.github/workflows/validate.yaml`: drop the
  `terraform/stages/0-fleet` matrix entry.
- `.github/workflows/tflint.yaml`: drop entry.
- `.github/workflows/tf-plan.yaml` / `tf-apply.yaml`: drop Stage 0
  matrix legs; downstream legs (Stage 1) lose their Stage-0 dependency.
- `terraform/stages/1-cluster/variables.tf`: remove
  `argo_aad_application_id`, `kargo_aad_application_object_id`,
  `fleet_kv_id` (replaced by `mgmt_cluster_kv_id` for spokes).
- `terraform/stages/1-cluster/outputs.tf`: drop Stage-0 passthroughs;
  add `MGMT_CLUSTER_KV_ID` and the four AAD-/UAMI- repo-var publishes.
- Delete `bootstrap/environment` `fleet_kv_secrets_user` role
  assignment.
- `init-gh-apps.sh`: no change (only writes PEMs to runner-pool KV;
  AAD-app-related secrets were never its concern).

### Step 6 — PLAN / STATUS / docs

Per AGENTS.md §3: STATUS updates in the same commits as the work; PLAN
updates are intent changes that land before/with the work.

- PLAN §1: hard-limit one mgmt cluster.
- PLAN §4: stage list — drop Stage 0; redescribe Stage 1 mgmt's
  expanded role.
- PLAN §13 (role assignments): redo matrix without Stage 0.
- PLAN §16 implementation-status callout: refresh.
- STATUS.md: bump every line tied to a Stage 0 item; add lines for
  the new Stage 1 mgmt responsibilities.
- `docs/adoption.md`: drop Stage 0 from §5.x ordering. §5.3 (Graph
  grant) still applies.
- `docs/naming.md`: KV rename.
- `docs/findings.md`: F26's mention of Stage 0 → updated.

### Step 7 — Validate end-to-end

- `terraform fmt -check -recursive`
- `terraform -chdir=terraform/bootstrap/fleet validate`
- `terraform -chdir=terraform/bootstrap/environment validate`
- `terraform -chdir=terraform/stages/1-cluster validate`
- `terraform -chdir=terraform/modules/fleet-identity test`
- `.github/workflows/validate.yaml` should still pass on a dry CI run.

### Step 8 — Adopter PR

Single PR against adopter `main`. Body documents the one-time fleet KV
recreate (step 3) for in-flight adopters.

After merge:
1. `terraform -chdir=terraform/bootstrap/fleet apply` — first pass.
   Creates runner-pool KV at new location; creates Argo + Kargo AAD
   apps + 2-year passwords; publishes
   `ARGO_AAD_APP_ID`/`KARGO_AAD_APP_ID`/`KARGO_AAD_APPLICATION_OBJECT_ID`
   repo vars. Mgmt cluster KV writes are skipped (KV doesn't exist
   yet).
2. `init-gh-apps.sh --keep` re-seeds App PEMs into the new runners KV.
3. `env-bootstrap.yaml env=mgmt apply` — creates fleet ACR + grants
   env UAMI ACR roles; publishes `ACR_*` repo vars.
4. `tf-apply.yaml` cluster=mgmt — creates mgmt cluster + mgmt KV +
   uami-kargo-mgmt; publishes `MGMT_CLUSTER_KV_ID`,
   `KARGO_MGMT_UAMI_*`, `MGMT_AKS_*` repo vars.
5. `terraform -chdir=terraform/bootstrap/fleet apply` — second pass.
   `MGMT_CLUSTER_KV_ID` now resolves; Argo + Kargo OIDC RP secrets
   land in mgmt cluster KV. Idempotent thereafter.
6. `env-bootstrap.yaml env=nonprod apply` — env UAMIs get AcrPull on
   fleet ACR.
7. `env-bootstrap.yaml env=prod apply`.
8. `tf-apply.yaml` cluster=nonprod/prod spokes.

## Risks

1. **`bootstrap/environment` env=mgmt blast radius grows.** A failed
   apply leaves a fleet-wide singleton (fleet ACR) in dirty env-state.
   Mitigated by azapi idempotency + the ACR's small surface area.

2. **Step 3 recreates the runner-pool KV.** For scopfleet (this
   walkthrough) this is fine — the existing KV holds two PEMs both
   trivially re-seedable via `init-gh-apps.sh --keep`.

3. **Stage 1 mgmt creates no AAD apps.** Step 4's Stage-1-mgmt
   draft was reverted; AAD apps now live in `bootstrap/fleet` and
   are operator-applied. Stage 1 mgmt holds no `azuread_*`
   resources and requires no Graph permission grants. The previously
   documented manual `Application.ReadWrite.OwnedBy` grant on
   `uami-fleet-mgmt` (`docs/adoption.md §5.3`) is no longer
   required.

4. **Spoke Stage 1 `var.mgmt_cluster_kv_id` is required.** First-time
   spoke applies must wait for mgmt Stage 1 to publish the repo var.
   Operator step, documented in adoption.md.

5. **`docs/findings.md` F26 (LAW private networking).** Independent of
   this refactor but touches the same surface; resolve F26 in a
   follow-up PR, not bundled.

## Out of scope

- ACR consolidation (single ACR for fleet + runner pool) — separate
  decision deferred until we own the runner image build pipeline.
- Multi-mgmt cluster support — explicitly forbidden by the new hard
  limit.
- F26 (LAW private-networking workaround).
- F25 (tf-apply plan replay).

## Done criteria

- `terraform/stages/0-fleet/` does not exist.
- No file under `terraform/` references `fleet_kv` (only `runners_kv`).
- `clusters/_fleet.yaml.tftpl` template renders `runners_keyvault`
  block; existing `keyvault` block deprecated and removed.
- Adopter walkthrough succeeds end-to-end without manual workarounds
  beyond the documented `docs/adoption.md §5.3` Graph grant.
- All `terraform validate` + fmt-check + module tests pass.
- PLAN, STATUS, docs/ reflect the new architecture.
