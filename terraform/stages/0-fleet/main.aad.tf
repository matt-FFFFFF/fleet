# main.aad.tf
#
# Argo + Kargo AAD application registrations. Each is a single-tenant OIDC
# client used by its respective per-cluster workload:
#
#   Argo  — one instance per cluster; the app is shared across all of them.
#           web.redirect_uris lists every cluster's Argo callback URL.
#   Kargo — one instance on the mgmt cluster only. web.redirect_uris lists
#           only the mgmt cluster(s) (usually exactly one).
#
# Federated Identity Credentials on these apps are added per cluster in
# Stage 2 (needs the AKS OIDC issuer URL). Stage 0 does NOT touch FICs.
#
# The RP `client_secret` on each app exists solely for the OIDC auth-code
# flow (human SSO login) — Argo/Dex upstream does not yet support
# `client_assertion` RP auth. We manage exactly the Argo secret here:
#   - azuread_application_password with end_date anchored to the
#     time_rotating resource via timeadd(..., "2160h") (90d validity)
#   - rotate_when_changed keyed off the same time_rotating resource
#     (60d cadence)
#   - create-before-destroy — old secret remains valid during the rotation
#     window so Argo (ESO-synced) does not see a gap
#   - resulting .value written to the fleet KV as a secret version
#
# The Kargo application_password is NOT created here — it's created by the
# mgmt cluster's Stage 1 (alongside the mgmt cluster KV that stores it),
# per PLAN §4 Stage 0/Stage 1.

# --- Owner-principal lookups ------------------------------------------------
#
# Per STATUS item 14, the Argo + Kargo apps list every Fleet UAMI that needs
# owner-scoped CRUD (via Graph `Application.ReadWrite.OwnedBy`) as an owner:
#
#   * `uami-fleet-stage0` — Stage 0 itself (auto-owner on create, but the
#     explicit entry makes re-applies idempotent and survives future
#     refactors that might split creation from rotation).
#   * `uami-fleet-<env>` for every env present in the cluster inventory —
#     Stage 1 mgmt (Kargo password rotation on `uami-fleet-mgmt`) and
#     Stage 2 every cluster (Argo per-cluster FIC writes on the env UAMI;
#     Kargo FIC on mgmt only under `uami-fleet-mgmt`).
#
# The UAMIs are authored by `bootstrap/fleet` (stage0) and
# `bootstrap/environment` (per-env). Stage 0 looks them up by display name
# at plan time; a missing UAMI surfaces as a plan-time data-source error,
# which is the desired failure mode on a fresh tenant where an env has not
# yet been bootstrapped.

data "azuread_service_principal" "stage0_uami" {
  display_name = "uami-fleet-stage0"
}

data "azuread_service_principal" "env_uami" {
  for_each     = toset(local.envs)
  display_name = "uami-fleet-${each.key}"
}

locals {
  # Sorted + de-duplicated owners list. Sorting pins iteration order to
  # prevent spurious plan diffs from set-iteration nondeterminism; distinct
  # absorbs the case where an adopter has also listed the UAMI by hand in
  # `clusters/_fleet.yaml`'s `aad.<app>.owners`.
  aad_app_owners_argocd = sort(distinct(concat(
    try(local.aad.argocd.owners, []),
    [data.azuread_service_principal.stage0_uami.object_id],
    [for sp in data.azuread_service_principal.env_uami : sp.object_id],
  )))
  aad_app_owners_kargo = sort(distinct(concat(
    try(local.aad.kargo.owners, []),
    [data.azuread_service_principal.stage0_uami.object_id],
    [for sp in data.azuread_service_principal.env_uami : sp.object_id],
  )))
}

# --- Argo AAD app ------------------------------------------------------------

resource "azuread_application" "argocd" {
  display_name     = local.aad.argocd.display_name
  sign_in_audience = "AzureADMyOrg"
  owners           = local.aad_app_owners_argocd

  group_membership_claims = ["SecurityGroup"]

  api {
    requested_access_token_version = 2
  }

  optional_claims {
    id_token {
      name = local.aad.argocd.group_claim_name
    }
    access_token {
      name = local.aad.argocd.group_claim_name
    }
  }

  web {
    redirect_uris = local.argo_redirect_uris
    implicit_grant {
      id_token_issuance_enabled = false
    }
  }
}

# --- Argo AAD service principal ---------------------------------------------

resource "azuread_service_principal" "argocd" {
  client_id                    = azuread_application.argocd.client_id
  app_role_assignment_required = false
  owners                       = local.aad_app_owners_argocd
}

# --- Argo RP client_secret rotation -----------------------------------------

resource "time_rotating" "argocd_secret" {
  rotation_days = 60
}

resource "azuread_application_password" "argocd" {
  application_id = azuread_application.argocd.id
  display_name   = "argocd-oidc-rp-secret"

  # 90-day TTL, re-anchored to the time_rotating creation timestamp so the
  # end_date resets each 60-day rotation window. Using `end_date_relative`
  # is deprecated in azuread ~> 3.8.
  end_date = timeadd(time_rotating.argocd_secret.id, "2160h")

  rotate_when_changed = {
    rotation = time_rotating.argocd_secret.id
  }

  lifecycle {
    create_before_destroy = true
  }
}

# --- Argo RP secret → fleet KV -----------------------------------------------
#
# Written as a new secret version on every rotation. ESO on each cluster
# fans it out into the `argocd` namespace; Argo reloads on secret change.

resource "azapi_resource" "argocd_oidc_client_secret" {
  type      = "Microsoft.KeyVault/vaults/secrets@2023-07-01"
  name      = "argocd-oidc-client-secret"
  parent_id = local.fleet_kv_id

  body = {
    properties = {
      value       = azuread_application_password.argocd.value
      contentType = "text/plain; aad-oidc-rp-secret; rotated-by-stage0"
    }
  }

  retry = {
    # Broad enough to cover the common RBAC-propagation error surfaces
    # KV returns immediately after a role assignment is created but
    # before AAD has propagated it data-plane-wide. azapi retries these
    # with exponential backoff until the ambient Stage 0 timeout.
    error_message_regex = [
      "Unauthorized",
      "Forbidden",
      "AuthorizationFailed",
      "does not have secrets set permission",
    ]
  }

  # Ordering: the role assignment must exist before the first write is
  # even attempted. The retry above handles propagation latency after
  # that.
  depends_on = [azapi_resource.ra_stage0_kv_secrets_officer]
}

# --- Kargo AAD app -----------------------------------------------------------

resource "azuread_application" "kargo" {
  display_name     = local.aad.kargo.display_name
  sign_in_audience = "AzureADMyOrg"
  owners           = local.aad_app_owners_kargo

  group_membership_claims = ["SecurityGroup"]

  api {
    requested_access_token_version = 2
  }

  optional_claims {
    id_token {
      name = local.aad.kargo.group_claim_name
    }
    access_token {
      name = local.aad.kargo.group_claim_name
    }
  }

  web {
    redirect_uris = local.kargo_redirect_uris
    implicit_grant {
      id_token_issuance_enabled = false
    }
  }
}

resource "azuread_service_principal" "kargo" {
  client_id                    = azuread_application.kargo.client_id
  app_role_assignment_required = false
  owners                       = local.aad_app_owners_kargo
}
