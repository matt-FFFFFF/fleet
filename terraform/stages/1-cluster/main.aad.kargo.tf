# stages/1-cluster/main.aad.kargo.tf
#
# Kargo AAD application registration — mgmt-cluster only (PLAN §1
# hub-and-spoke: Kargo runs only on the mgmt cluster).
#
# Pre-refactor home: terraform/stages/0-fleet/main.aad.tf (Kargo half).
# Moved here (REFACTOR.md Step 4) so Stage 1 mgmt owns the AAD app
# alongside the Kargo OIDC password rotation that already lives in
# main.kv.tf (`azuread_application_password.kargo_oidc_secret`).
#
# `redirect_uris` is a single mgmt-cluster-local URI (length-1 mgmt
# enforced by the bootstrap/environment env=mgmt precondition).
#
# The RP `client_secret` itself is NOT created here — it lives in
# `azuread_application_password.kargo_oidc_secret` (main.kv.tf), which
# now references `azuread_application.kargo[0].id` directly instead of
# the pre-refactor `var.kargo_aad_application_object_id` repo variable.

locals {
  kargo_aad = try(local.fleet.aad.kargo, null)

  kargo_redirect_uri_mgmt = local.mgmt_role_cluster ? (
    "https://kargo.${local.cluster.name}.${local.cluster.region}.${local.cluster.env}.${try(local.fleet.dns.fleet_root, "")}/auth/callback"
  ) : null
}

resource "azuread_application" "kargo" {
  count = local.mgmt_role_cluster ? 1 : 0

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
    redirect_uris = [local.kargo_redirect_uri_mgmt]
    implicit_grant {
      id_token_issuance_enabled = false
    }
  }

  lifecycle {
    precondition {
      condition     = local.kargo_aad != null && try(local.kargo_aad.display_name, null) != null && try(local.kargo_aad.group_claim_name, null) != null
      error_message = "_fleet.yaml.aad.kargo.{display_name,group_claim_name} are required on the management cluster."
    }
  }
}

resource "azuread_service_principal" "kargo" {
  count = local.mgmt_role_cluster ? 1 : 0

  client_id                    = azuread_application.kargo[0].client_id
  app_role_assignment_required = false
}
