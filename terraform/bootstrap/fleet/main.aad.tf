# bootstrap/fleet/main.aad.tf
#
# Argo CD + Kargo AAD application registrations + service principals +
# long-lived RP `client_secret` values. Owned by `bootstrap/fleet`
# (operator-applied) per PLAN §4 Stage -1.
#
# Why `bootstrap/fleet` and not Stage 1 mgmt:
#   - AAD-app creation requires Microsoft Graph permissions
#     (Cloud Application Administrator / Global Administrator) that
#     the operator already holds via interactive `az login`. No
#     standing Graph grant needs to be issued on any UAMI.
#   - Stage 1 mgmt runs on every cluster PR via the `fleet-mgmt`
#     UAMI; placing AAD-app authority there would require granting
#     `Application.ReadWrite.OwnedBy` on that UAMI, expanding the
#     blast radius of any cluster-config PR to "can mint/delete AAD
#     apps".
#
# Two-pass apply (chicken/egg with the mgmt cluster KV):
#   Pass 1 — bootstrap/fleet apply (no mgmt cluster KV exists yet):
#     - AAD apps + SPs + 2-year passwords created.
#     - Repo vars ARGO_AAD_APP_ID / KARGO_AAD_APP_ID /
#       KARGO_AAD_APPLICATION_OBJECT_ID published.
#     - KV writes skipped (count = 0 when var.mgmt_cluster_kv_id == null).
#   Pass 2 — bootstrap/fleet apply (after Stage 1 mgmt has
#   published MGMT_CLUSTER_KV_ID and operator has set
#   var.mgmt_cluster_kv_id):
#     - Operator self-grant of `Key Vault Secrets Officer` on the
#       mgmt cluster KV (so the data-plane PUT below succeeds).
#     - Secret values written via azapi data-plane PUT.
#   Idempotent thereafter.
#
# Secret rotation:
#   No `time_rotating` cadence. `azuread_application_password.end_date`
#   is set to a 2-year window from initial create. Re-roll on demand
#   by the operator (taint the password resource or bump
#   `var.argocd_rp_secret_version` / `var.kargo_rp_secret_version`).

# -----------------------------------------------------------------------------
# Mgmt cluster discovery — find the single mgmt cluster.yaml so we can
# derive the OIDC redirect URI per PLAN §1 (`length(mgmt_clusters) == 1`
# is enforced upstream by `bootstrap/environment` env=mgmt; we re-assert
# here as a precondition).
# -----------------------------------------------------------------------------

locals {
  mgmt_cluster_files = fileset("${path.module}/../../../clusters/mgmt", "**/cluster.yaml")
  # Cluster identity (env/region/name) is derived from the file path
  # ("<region>/<name>/cluster.yaml"), matching the contract in
  # `config-loader/load.sh` and `docs/naming.md`. The yaml body itself
  # only carries `cluster.role` + `resource_group`; cardinality is
  # asserted on the path list before we touch the body.
  mgmt_cluster_paths = [
    for f in local.mgmt_cluster_files : {
      env    = "mgmt"
      region = split("/", f)[0]
      name   = split("/", f)[1]
    }
  ]
  mgmt_cluster = length(local.mgmt_cluster_paths) == 1 ? local.mgmt_cluster_paths[0] : null

  fleet_root = try(local.fleet_doc.dns.fleet_root, null)

  argocd_aad = try(local.fleet_doc.aad.argocd, null)
  kargo_aad  = try(local.fleet_doc.aad.kargo, null)

  argocd_redirect_uri = local.mgmt_cluster != null && local.fleet_root != null ? (
    "https://argocd.${local.mgmt_cluster.name}.${local.mgmt_cluster.region}.${local.mgmt_cluster.env}.${local.fleet_root}/auth/callback"
  ) : null

  kargo_redirect_uri = local.mgmt_cluster != null && local.fleet_root != null ? (
    "https://kargo.${local.mgmt_cluster.name}.${local.mgmt_cluster.region}.${local.mgmt_cluster.env}.${local.fleet_root}/auth/callback"
  ) : null

  # Two-pass gate: KV writes (and the role assignment that enables
  # them) only materialize once the operator has set
  # `var.mgmt_cluster_kv_id` from the `MGMT_CLUSTER_KV_ID` repo var
  # published by Stage 1 mgmt.
  mgmt_kv_writes_enabled = var.mgmt_cluster_kv_id != null
}

# -----------------------------------------------------------------------------
# Cardinality + presence preconditions (one-time, fail-fast).
# -----------------------------------------------------------------------------

check "mgmt_cluster_singleton" {
  assert {
    condition     = length(local.mgmt_cluster_paths) == 1
    error_message = "Expected exactly one clusters/mgmt/**/cluster.yaml; found ${length(local.mgmt_cluster_paths)}. Hub-and-spoke Argo + singleton Kargo require exactly one mgmt cluster (PLAN §1)."
  }
}

check "aad_config_present" {
  assert {
    condition     = local.argocd_aad != null && try(local.argocd_aad.display_name, null) != null && try(local.argocd_aad.group_claim_name, null) != null
    error_message = "_fleet.yaml.aad.argocd.{display_name,group_claim_name} are required."
  }
  assert {
    condition     = local.kargo_aad != null && try(local.kargo_aad.display_name, null) != null && try(local.kargo_aad.group_claim_name, null) != null
    error_message = "_fleet.yaml.aad.kargo.{display_name,group_claim_name} are required."
  }
  assert {
    condition     = local.fleet_root != null
    error_message = "_fleet.yaml.dns.fleet_root is required (consumed by Argo + Kargo redirect URI derivation)."
  }
}

# -----------------------------------------------------------------------------
# Argo CD AAD application + service principal.
# -----------------------------------------------------------------------------

resource "azuread_application" "argocd" {
  display_name     = local.argocd_aad.display_name
  sign_in_audience = "AzureADMyOrg"

  group_membership_claims = ["SecurityGroup"]

  api {
    requested_access_token_version = 2
  }

  optional_claims {
    id_token {
      name = local.argocd_aad.group_claim_name
    }
    access_token {
      name = local.argocd_aad.group_claim_name
    }
  }

  web {
    redirect_uris = [local.argocd_redirect_uri]
    implicit_grant {
      id_token_issuance_enabled = false
    }
  }
}

resource "azuread_service_principal" "argocd" {
  client_id                    = azuread_application.argocd.client_id
  app_role_assignment_required = false
}

# -----------------------------------------------------------------------------
# Kargo AAD application + service principal.
# -----------------------------------------------------------------------------

resource "azuread_application" "kargo" {
  display_name     = local.kargo_aad.display_name
  sign_in_audience = "AzureADMyOrg"

  group_membership_claims = ["SecurityGroup"]

  api {
    requested_access_token_version = 2
  }

  optional_claims {
    id_token {
      name = local.kargo_aad.group_claim_name
    }
    access_token {
      name = local.kargo_aad.group_claim_name
    }
  }

  web {
    redirect_uris = [local.kargo_redirect_uri]
    implicit_grant {
      id_token_issuance_enabled = false
    }
  }
}

resource "azuread_service_principal" "kargo" {
  client_id                    = azuread_application.kargo.client_id
  app_role_assignment_required = false
}

# -----------------------------------------------------------------------------
# RP `client_secret` passwords — long-lived (2-year), no auto-rotation.
#
# Re-roll: bump `var.argocd_rp_secret_version` /
# `var.kargo_rp_secret_version` (or `terraform taint` the resource).
# Each version bump triggers a fresh password value with a fresh
# 2-year `end_date`.
# -----------------------------------------------------------------------------

resource "time_static" "argocd_rp_secret_anchor" {
  triggers = {
    version = var.argocd_rp_secret_version
  }
}

resource "azuread_application_password" "argocd" {
  application_id = azuread_application.argocd.id
  display_name   = "argocd-oidc-rp-secret"
  # 2 years from anchor; anchor only changes when the version is bumped,
  # so end_date is stable across re-applies until the operator re-rolls.
  end_date = timeadd(time_static.argocd_rp_secret_anchor.rfc3339, "17520h")

  rotate_when_changed = {
    version = var.argocd_rp_secret_version
  }

  lifecycle {
    create_before_destroy = true
  }
}

resource "time_static" "kargo_rp_secret_anchor" {
  triggers = {
    version = var.kargo_rp_secret_version
  }
}

resource "azuread_application_password" "kargo" {
  application_id = azuread_application.kargo.id
  display_name   = "kargo-oidc-rp-secret"
  end_date       = timeadd(time_static.kargo_rp_secret_anchor.rfc3339, "17520h")

  rotate_when_changed = {
    version = var.kargo_rp_secret_version
  }

  lifecycle {
    create_before_destroy = true
  }
}

# -----------------------------------------------------------------------------
# Mgmt cluster KV writes (second pass only).
#
# The operator running this apply (interactive `az login`, tenant
# admin + subscription owner) is granted `Key Vault Secrets Officer`
# on the mgmt cluster KV in this same plan so the data-plane PUTs
# below succeed without an out-of-band step. The role assignment is
# scoped to the mgmt cluster KV id and is idempotent.
# -----------------------------------------------------------------------------

data "azuread_client_config" "current" {
  count = local.mgmt_kv_writes_enabled ? 1 : 0
}

resource "azapi_resource" "operator_mgmt_kv_secrets_officer" {
  count = local.mgmt_kv_writes_enabled ? 1 : 0

  type      = "Microsoft.Authorization/roleAssignments@2022-04-01"
  parent_id = var.mgmt_cluster_kv_id
  # Deterministic GUID v5 over (scope, principalId, role) so re-runs
  # don't produce duplicate assignments.
  name = uuidv5("oid", "${var.mgmt_cluster_kv_id}|${data.azuread_client_config.current[0].object_id}|Key Vault Secrets Officer")

  body = {
    properties = {
      principalId   = data.azuread_client_config.current[0].object_id
      principalType = "User"
      # Key Vault Secrets Officer (built-in)
      roleDefinitionId = "/providers/Microsoft.Authorization/roleDefinitions/b86a8fe4-44ce-4948-aee5-eccb2c155cd7"
    }
  }

  retry = {
    error_message_regex = ["AuthorizationFailed", "PrincipalNotFound"]
  }
}

# Resolve the KV vaultUri for data-plane writes. azapi data source
# returns the parent KV's properties; we extract `vaultUri`.
data "azapi_resource" "mgmt_cluster_kv" {
  count = local.mgmt_kv_writes_enabled ? 1 : 0

  type        = "Microsoft.KeyVault/vaults@2023-07-01"
  resource_id = var.mgmt_cluster_kv_id

  response_export_values = ["properties.vaultUri"]
}

resource "azapi_data_plane_resource" "argocd_oidc_client_secret" {
  count = local.mgmt_kv_writes_enabled ? 1 : 0

  type      = "Microsoft.KeyVault/vaults/secrets@7.4"
  parent_id = trimsuffix(trimprefix(data.azapi_resource.mgmt_cluster_kv[0].output.properties.vaultUri, "https://"), "/")
  name      = "argocd-oidc-client-secret"

  body = {
    contentType = "text/plain; aad-oidc-rp-secret; owned-by-bootstrap-fleet"
  }

  sensitive_body = {
    value = azuread_application_password.argocd.value
  }

  sensitive_body_version = {
    value = var.argocd_rp_secret_version
  }

  depends_on = [
    azapi_resource.operator_mgmt_kv_secrets_officer,
  ]
}

resource "azapi_data_plane_resource" "kargo_oidc_client_secret" {
  count = local.mgmt_kv_writes_enabled ? 1 : 0

  type      = "Microsoft.KeyVault/vaults/secrets@7.4"
  parent_id = trimsuffix(trimprefix(data.azapi_resource.mgmt_cluster_kv[0].output.properties.vaultUri, "https://"), "/")
  name      = "kargo-oidc-client-secret"

  body = {
    contentType = "text/plain; aad-oidc-rp-secret; owned-by-bootstrap-fleet"
  }

  sensitive_body = {
    value = azuread_application_password.kargo.value
  }

  sensitive_body_version = {
    value = var.kargo_rp_secret_version
  }

  depends_on = [
    azapi_resource.operator_mgmt_kv_secrets_officer,
  ]
}

# -----------------------------------------------------------------------------
# Repo-level GitHub Actions variables.
#
# Consumed by Stage 1 mgmt's main.identities.kargo.tf (FIC subject
# parent_id), every cluster's Stage 2 (Argo Helm OIDC clientID +
# `platform-identity` secret), and mgmt Stage 2 (Kargo Helm OIDC
# clientID + Kargo FIC parent_id).
#
# REPOSITORY-scoped (not env-scoped) — the AAD apps are fleet-wide
# singletons, and the IDs flow into every env's CI matrix legs.
# -----------------------------------------------------------------------------

resource "github_actions_variable" "argocd_aad_app_id" {
  repository    = local.fleet.github_repo
  variable_name = "ARGO_AAD_APP_ID"
  value         = azuread_application.argocd.client_id
}

resource "github_actions_variable" "kargo_aad_app_id" {
  repository    = local.fleet.github_repo
  variable_name = "KARGO_AAD_APP_ID"
  value         = azuread_application.kargo.client_id
}

resource "github_actions_variable" "kargo_aad_app_object_id" {
  repository    = local.fleet.github_repo
  variable_name = "KARGO_AAD_APPLICATION_OBJECT_ID"
  value         = azuread_application.kargo.object_id
}
