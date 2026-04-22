# stages/1-cluster/main.kv.tf
#
# Per-cluster Key Vault (PLAN §4 Stage 1 lines 1765-1784). Named
# `kv-<cluster.name>` (truncated to 24 chars) in `<cluster.resource_group>`
# — both derived by `config-loader/load.sh` into `derived.keyvault_name`
# and `derived.keyvault_resource_group` (override paths live on
# `platform.keyvault.{name,resource_group}`).
#
# Holds cluster-local secrets (TLS wildcards, team app secrets, etc.).
# Role assignments on this KV (ESO UAMI → KV Secrets User) live in
# main.rbac.tf; the module itself stays scope-agnostic so an operator
# could reuse it if a second fleet-local KV is ever introduced.
#
# On the **management cluster only** (opted in via
# `cluster.role == "management"`), this file also mints the
# `kargo-oidc-client-secret` via an `azuread_application_password` on
# the Stage 0-owned Kargo AAD app, rotated every 60 days via a
# `time_rotating` resource, and writes the result into the cluster KV
# as an azapi KV secret. The `kargo-github-app-pem` referenced by PLAN
# §4 Stage 1 is NOT authored here — it's seeded out-of-band (initial
# manual write by the Kargo GH App operator or via a one-shot
# `bootstrap/` helper) and ESO takes over ongoing rotation per PLAN
# §8. This file documents the expected secret name but creates no
# resource for it.

module "cluster_kv" {
  source = "../../modules/cluster-kv"

  name      = local.derived.keyvault_name
  location  = local.cluster.region
  parent_id = "/subscriptions/${local.cluster.subscription_id}/resourceGroups/${local.derived.keyvault_resource_group}"
  tenant_id = local.fleet.tenant_id

  tags = {
    fleet       = local.fleet.name
    environment = local.cluster.env
    region      = local.cluster.region
    cluster     = local.cluster.name
    role        = try(local.cluster.role, "workload")
    stage       = "1-cluster"
  }
}

# --- Kargo OIDC client-secret rotation (mgmt cluster only) -----------------
#
# `count` gate keeps these dormant on every workload cluster. The
# Kargo AAD app is owned by Stage 0 — this stage only writes a password
# on it (requires `Application.ReadWrite.OwnedBy` on the Stage 0-owned
# app; see the mgmt-env UAMI's Entra RBAC).
#
# Rotation policy: 60-day cadence, 90-day end_date — giving a 30-day
# overlap window to the previous secret during rollover. The
# `time_rotating.kargo_oidc` resource drives rotation; its rotation
# schedule feeds `azuread_application_password.rotate_when_changed`
# to replace the password value. `create_before_destroy` ensures the
# new password exists in the KV before the old one is revoked.

resource "time_rotating" "kargo_oidc_secret" {
  count = local.mgmt_role_cluster ? 1 : 0

  rotation_days = 60
}

resource "azuread_application_password" "kargo_oidc_secret" {
  count = local.mgmt_role_cluster ? 1 : 0

  application_id = "/applications/${var.kargo_aad_application_object_id}"
  display_name   = "kargo-oidc-client-secret"
  # 90-day end_date (60d rotation + 30d overlap window during rollover).
  # Anchored to the current rotation tick so the new password's lifetime
  # is always relative to *this* rotation, not first-apply wall clock.
  end_date = timeadd(time_rotating.kargo_oidc_secret[0].rotation_rfc3339, "2160h")

  rotate_when_changed = {
    rotation = time_rotating.kargo_oidc_secret[0].id
  }

  lifecycle {
    create_before_destroy = true
    precondition {
      condition     = var.kargo_aad_application_object_id != null
      error_message = "kargo_aad_application_object_id is required on management clusters (cluster.role == \"management\"). Publish the Stage 0 output `kargo_aad_application_object_id` as the `KARGO_AAD_APPLICATION_OBJECT_ID` repo variable and wire it into TF_VAR_kargo_aad_application_object_id in tf-apply.yaml."
    }
  }
}

resource "azapi_resource" "kargo_oidc_secret" {
  count = local.mgmt_role_cluster ? 1 : 0

  type      = "Microsoft.KeyVault/vaults/secrets@2023-07-01"
  name      = "kargo-oidc-client-secret"
  parent_id = module.cluster_kv.resource_id

  body = {
    properties = {
      value       = azuread_application_password.kargo_oidc_secret[0].value
      contentType = "text/plain; charset=utf-8"
      attributes = {
        enabled = true
      }
    }
  }

  # The KV secret value is sensitive; surface only the id.
  response_export_values = ["id"]
}
