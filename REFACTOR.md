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
| Argo AAD app + service principal + RP secret rotation | Stage 1 mgmt (Argo is mgmt-only per PLAN §1 hub-and-spoke) |
| Kargo AAD app + service principal                     | Stage 1 mgmt (mgmt-only) |
| `uami-kargo-mgmt` + AcrPull on fleet ACR              | Stage 1 mgmt (mgmt-only; FIC already lives in Stage 2 mgmt) |
| KV Secrets Officer for stage0 identity                | Deleted (no Stage 0 identity exists post-refactor) |
| `argocd-oidc-client-secret` rotation target           | Mgmt cluster KV (already exists, Stage 1 mgmt) |
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

4. **Argo + Kargo AAD apps move to Stage 1 mgmt.** Gated on
   `cluster.role == "management"`. Repo-var publishes
   (`ARGO_AAD_APP_ID`, `KARGO_AAD_APP_ID`, `KARGO_AAD_APPLICATION_OBJECT_ID`,
   `KARGO_MGMT_UAMI_PRINCIPAL_ID`, `KARGO_MGMT_UAMI_CLIENT_ID`) move
   from Stage 0 → Stage 1 mgmt repo-level vars (Stage 1 already publishes
   `MGMT_AKS_*` repo vars; this is an extension of that pattern).

5. **`uami-kargo-mgmt` moves to Stage 1 mgmt.** AcrPull on fleet ACR
   stays — same scope, different stage. FIC binding the UAMI to the
   Kargo controller SA already lives in Stage 2 mgmt; unchanged.

6. **Argo OIDC RP secret rotation moves to Stage 1 mgmt.** Written to
   the **mgmt cluster KV** (already created by Stage 1 mgmt) under the
   same secret name. ESO on every cluster (mgmt + spokes) reads it
   from the mgmt cluster KV. ESO UAMI's KV-Secrets-User grant follows
   the secret: spoke Stage 1's `ra_eso_fleet_kv` becomes
   `ra_eso_mgmt_cluster_kv`, scoped to the mgmt cluster KV's resource
   id (published as a Stage 1 mgmt repo var).

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

9. **`docs/adoption.md` ordering simplifies.** §5.3's manual Graph grant
   recipe still applies (operator runs `az rest` once after env=mgmt to
   give `uami-fleet-mgmt` Graph perms). Stage 0 references removed.

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

### Step 4 — Move Argo / Kargo AAD apps to Stage 1 mgmt

- `terraform/stages/1-cluster/main.aad.argocd.tf` (new, gated
  `count = local.mgmt_role_cluster ? 1 : 0`): Argo AAD app + SP +
  `time_rotating` + `azuread_application_password` + write to mgmt
  cluster KV.
- `terraform/stages/1-cluster/main.aad.kargo.tf` (new, gated likewise):
  Kargo AAD app + SP. Kargo `azuread_application_password` already
  lives in `stages/1-cluster/main.kv.tf` — keep there, but its
  `application_id` reference flips from
  `var.kargo_aad_application_object_id` to the local resource id.
- `terraform/stages/1-cluster/main.identities.kargo.tf` (new, gated):
  `uami-kargo-mgmt` + AcrPull on fleet ACR.
- `redirect_uris` derive from the local cluster (just one mgmt
  cluster per fleet, by step 0's hard limit). The `for_each` over
  `mgmt_clusters` collapses to a singleton.
- Owner-principal lookups: `stage0_uami` data source disappears
  entirely; `mgmt_uami` is the Stage 1 executor itself
  (`data.azuread_client_config.current.object_id`), so no data-source
  lookup needed.
- Repo-var publishes via `github_actions_variable`:
  `ARGO_AAD_APP_ID`, `KARGO_AAD_APP_ID`,
  `KARGO_AAD_APPLICATION_OBJECT_ID`,
  `KARGO_MGMT_UAMI_PRINCIPAL_ID`, `KARGO_MGMT_UAMI_CLIENT_ID`.
- Move the `argocd-oidc-client-secret` rotation target → mgmt cluster
  KV. Publish `MGMT_CLUSTER_KV_ID` as a Stage 1 mgmt repo var so
  spoke Stage 1s can grant ESO UAMI `Key Vault Secrets User` on it.
- Spoke Stage 1's `ra_eso_fleet_kv` → `ra_eso_mgmt_cluster_kv`,
  consuming `var.mgmt_cluster_kv_id` (new tfvar).

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
1. `terraform -chdir=terraform/bootstrap/fleet apply` (creates
   runner-pool KV at new location; `init-gh-apps.sh --keep` re-seeds
   PEMs).
2. `env-bootstrap.yaml env=mgmt apply` (creates fleet ACR + grants env
   UAMI ACR roles; publishes ACR repo vars).
3. Manual Graph grant on `uami-fleet-mgmt` (`docs/adoption.md §5.3`).
4. `tf-apply.yaml` cluster=mgmt (creates mgmt cluster + Argo/Kargo
   AAD apps + uami-kargo-mgmt; publishes AAD/UAMI repo vars).
5. `env-bootstrap.yaml env=nonprod apply` (env UAMIs get AcrPull on
   fleet ACR — now exists).
6. `env-bootstrap.yaml env=prod apply`.
7. `tf-apply.yaml` cluster=nonprod/prod spokes.

## Risks

1. **`bootstrap/environment` env=mgmt blast radius grows.** A failed
   apply leaves a fleet-wide singleton (fleet ACR) in dirty env-state.
   Mitigated by azapi idempotency + the ACR's small surface area.

2. **Step 3 recreates the runner-pool KV.** For scopfleet (this
   walkthrough) this is fine — the existing KV holds two PEMs both
   trivially re-seedable via `init-gh-apps.sh --keep`.

3. **Stage 1 mgmt now creates AAD apps on first apply.** The mgmt
   Stage 1 executor is `uami-fleet-mgmt`, which already gets the
   manual Graph `Application.ReadWrite.OwnedBy` grant per §5.3. No
   new permissions required.

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
