# stages/1-cluster/main.aad.argocd.tf
#
# Argo CD AAD application registration — mgmt-cluster only (PLAN §1
# hub-and-spoke: Argo runs only on the mgmt cluster; spokes register
# as cluster `Secret`s on mgmt's Argo and authenticate inbound via
# per-spoke `uami-argocd-spoke-<cluster>` UAMI FICs created in
# main.identities.tf, not on this AAD app).
#
# Pre-refactor home: terraform/stages/0-fleet/main.aad.tf. Moved here
# (REFACTOR.md Step 4) so Stage 1 mgmt owns the AAD app, the RP-secret
# rotation, and the secret write into the mgmt cluster's own KV
# (consumed via ESO from every cluster, mgmt + spokes — see
# main.rbac.tf `ra_eso_mgmt_cluster_kv`).
#
# `redirect_uris` is a single mgmt-cluster-local URI. The new
# `length(mgmt_clusters) == 1` precondition in `bootstrap/environment`
# env=mgmt enforces fleet-wide singleton mgmt; no spoke contribution.
#
# The RP `client_secret` exists solely for the OIDC auth-code flow
# (human SSO login) — Argo/Dex upstream does not yet support
# `client_assertion` RP auth. Rotation policy mirrors the pre-refactor
# Stage 0 implementation:
#   - 60-day rotation cadence (`time_rotating.argocd_oidc_secret`)
#   - 90-day password validity (`timeadd(..., "2160h")`) → 30-day
#     overlap during rollover
#   - `create_before_destroy` so Argo (ESO-synced) sees no gap
#   - resulting `.value` written to the mgmt cluster KV under
#     `argocd-oidc-client-secret`; ESO on every cluster fans it into
#     the `argocd` namespace.

locals {
  argocd_aad = try(local.fleet.aad.argocd, null)

  # Single mgmt-cluster redirect URI (singleton enforced upstream by
  # bootstrap/environment env=mgmt's mgmt-cluster-cardinality
  # precondition; no `for_each` collapse needed).
  argocd_redirect_uri_mgmt = local.mgmt_role_cluster ? (
    "https://argocd.${local.cluster.name}.${local.cluster.region}.${local.cluster.env}.${try(local.fleet.dns.fleet_root, "")}/auth/callback"
  ) : null
}

# --- Argo AAD app -----------------------------------------------------------

resource "azuread_application" "argocd" {
  count = local.mgmt_role_cluster ? 1 : 0

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
    redirect_uris = [local.argocd_redirect_uri_mgmt]
    implicit_grant {
      id_token_issuance_enabled = false
    }
  }

  lifecycle {
    precondition {
      condition     = local.argocd_aad != null && try(local.argocd_aad.display_name, null) != null && try(local.argocd_aad.group_claim_name, null) != null
      error_message = "_fleet.yaml.aad.argocd.{display_name,group_claim_name} are required on the management cluster."
    }
    precondition {
      condition     = try(local.fleet.dns.fleet_root, null) != null
      error_message = "_fleet.yaml.dns.fleet_root is required on the management cluster (consumed by Argo redirect URI derivation)."
    }
  }
}

# --- Argo AAD service principal ---------------------------------------------

resource "azuread_service_principal" "argocd" {
  count = local.mgmt_role_cluster ? 1 : 0

  client_id                    = azuread_application.argocd[0].client_id
  app_role_assignment_required = false
}

# --- Argo RP client_secret rotation -----------------------------------------
#
# 60d rotation cadence; 90d end_date anchored to the time_rotating
# resource so each rotation issues a fresh 90-day window. Using
# `end_date_relative` is deprecated in azuread ~> 3.8.

resource "time_rotating" "argocd_oidc_secret" {
  count = local.mgmt_role_cluster ? 1 : 0

  rotation_days = 60
}

resource "azuread_application_password" "argocd" {
  count = local.mgmt_role_cluster ? 1 : 0

  application_id = azuread_application.argocd[0].id
  display_name   = "argocd-oidc-rp-secret"
  end_date       = timeadd(time_rotating.argocd_oidc_secret[0].id, "2160h")

  rotate_when_changed = {
    rotation = time_rotating.argocd_oidc_secret[0].id
  }

  lifecycle {
    create_before_destroy = true
  }
}

# --- Argo RP secret → mgmt cluster KV ---------------------------------------
#
# Written as a new secret version on every rotation. ESO on every
# cluster (mgmt + spokes) reads it from THIS KV (via the
# `ra_eso_mgmt_cluster_kv` role assignment in main.rbac.tf, scoped to
# this KV's resource id) and fans it into the `argocd` namespace.
# Ordering: the role assignment for the cluster's own ESO UAMI is in
# main.rbac.tf and depends on this secret transitively via the cluster
# KV; cross-cluster spoke ESO UAMIs read after Stage 1 spoke apply
# completes.

resource "azapi_resource" "argocd_oidc_client_secret" {
  count = local.mgmt_role_cluster ? 1 : 0

  type      = "Microsoft.KeyVault/vaults/secrets@2023-07-01"
  name      = "argocd-oidc-client-secret"
  parent_id = module.cluster_kv.resource_id

  body = {
    properties = {
      value       = azuread_application_password.argocd[0].value
      contentType = "text/plain; aad-oidc-rp-secret; rotated-by-stage1-mgmt"
    }
  }

  retry = {
    error_message_regex = [
      "Unauthorized",
      "Forbidden",
      "AuthorizationFailed",
      "does not have secrets set permission",
    ]
  }

  response_export_values = ["id"]
}
