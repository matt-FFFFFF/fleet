# main.aad.tf
#
# Argo + Kargo AAD application registrations. Each is a single-tenant OIDC
# client used by the (single) mgmt-cluster workload:
#
#   Argo  — one instance, mgmt only (PLAN §1 hub-and-spoke). Spoke clusters
#           register into mgmt's Argo as cluster `Secret`s; they do not run
#           Argo and so do not appear in `web.redirect_uris`.
#   Kargo — one instance, mgmt only. web.redirect_uris lists the mgmt
#           cluster(s) (usually exactly one).
#
# Both redirect URI lists are derived from `local.mgmt_clusters` (see
# main.tf), so adding/removing a non-mgmt cluster never re-plans Argo or
# Kargo here.
#
# Federated Identity Credentials on the Argo / Kargo *AAD apps* are
# created on the mgmt cluster only (Stage 1 mgmt for Kargo password
# rotation + Kargo FIC; Stage 1 mgmt for Argo FICs once the mgmt-side
# Argo SAs need workload-identity AAD calls). Spoke clusters' Argo
# inbound auth uses the per-spoke `uami-argocd-spoke-<cluster>` UAMI's
# FICs (Stage 1, on the spoke's *UAMI*, not on the AAD app) — see PLAN
# §4 Stage 1.
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
# Per PLAN §1 hub-and-spoke, the Argo + Kargo AAD apps are mgmt-only
# singletons. The only UAMIs that ever mutate them post-create are:
#
#   * `uami-fleet-stage0` — Stage 0 itself (auto-owner on create, but the
#     explicit entry makes re-applies idempotent and survives future
#     refactors that might split creation from rotation).
#   * `uami-fleet-mgmt` — Stage 1 mgmt cluster (Kargo password rotation;
#     mgmt-side Argo / Kargo FIC writes once those land).
#
# Per-env UAMIs in non-mgmt envs (`uami-fleet-nonprod`,
# `uami-fleet-prod`, …) are NOT owners — they have no reason to mutate
# the Argo or Kargo apps, and dropping them eliminates the need for
# `bootstrap/fleet` to grant `AppRoleAssignment.ReadWrite.All` to
# `uami-fleet-meta`. See `terraform/bootstrap/fleet/main.identities.tf`
# and `docs/adoption.md §5.1`.
#
# Both UAMIs are looked up by display name at plan time. A missing UAMI
# surfaces as a plan-time data-source error — the desired failure mode
# on a fresh tenant where env=mgmt has not yet been bootstrapped.

data "azuread_service_principal" "stage0_uami" {
  display_name = "uami-fleet-stage0"
}

data "azuread_service_principal" "mgmt_uami" {
  display_name = "uami-fleet-mgmt"
}

locals {
  # Sorted + de-duplicated owners list. Sorting pins iteration order to
  # prevent spurious plan diffs from set-iteration nondeterminism; distinct
  # absorbs the case where an adopter has also listed the UAMI by hand in
  # `clusters/_fleet.yaml`'s `aad.<app>.owners`.
  aad_app_owners_argocd = sort(distinct(concat(
    try(local.aad.argocd.owners, []),
    [data.azuread_service_principal.stage0_uami.object_id],
    [data.azuread_service_principal.mgmt_uami.object_id],
  )))
  aad_app_owners_kargo = sort(distinct(concat(
    try(local.aad.kargo.owners, []),
    [data.azuread_service_principal.stage0_uami.object_id],
    [data.azuread_service_principal.mgmt_uami.object_id],
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
