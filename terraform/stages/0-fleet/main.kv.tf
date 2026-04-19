# main.kv.tf
#
# Fleet Key Vault — created by bootstrap/fleet (Stage -1) so the runner
# pool's KV-reference for the GH App PEM resolves at module-apply time.
# See terraform/bootstrap/fleet/main.kv.tf for the resource definition,
# private-endpoint wiring, and the Key Vault Secrets User role
# assignment granted to `uami-fleet-runners`.
#
# Stage 0 consumes the existing KV: the vault id is fully derivable from
# `_fleet.yaml` via the same naming contract bootstrap/fleet uses, so no
# `data "azapi_resource"` lookup is required (and avoiding the read-time
# permission requirement keeps this stage executable as soon as the KV
# exists, regardless of whether the Stage 0 identity has KV data-plane
# reads).
#
# What Stage 0 owns on the KV:
#
#   - `Key Vault Secrets Officer` at vault scope for the Stage 0 executor
#     (this file). Rotations (argocd-oidc-client-secret, per PLAN §4 Stage
#     0) need to write new secret versions.
#
# What Stage 0 seeds into the KV (in sibling files):
#
#   - argocd-oidc-client-secret   main.aad.tf (60d rotation)
#   - argocd-github-app-pem       via `init-gh-apps.sh` (PLAN §16.4); not
#                                 in this scaffold yet, see PLAN §16
#                                 implementation-status callout.
#
# The fleet-runners PEM (`fleet-runners-app-pem`) is consumed by Stage -1
# and seeded by `init-gh-apps.sh` as a post-bootstrap operator step; it
# is not a Stage 0 responsibility.
#
# Mgmt-only secrets (kargo-*) live in the mgmt cluster's KV (Stage 1).

locals {
  # Reconstructed KV id. Same derivation as bootstrap/fleet + the KV is
  # colocated with the ACR in rg-fleet-shared.
  fleet_kv_id = join("/", [
    "/subscriptions", local.derived.acr_subscription_id,
    "resourceGroups", local.derived.fleet_kv_resource_group,
    "providers/Microsoft.KeyVault/vaults", local.derived.fleet_kv_name,
  ])

  # Built-in role guid:
  #   Key Vault Secrets Officer  b86a8fe4-44ce-4948-aee5-eccb2c155cd7
  role_kv_secrets_officer = "b86a8fe4-44ce-4948-aee5-eccb2c155cd7"
}

# Surface _fleet.yaml drift early: the RG colocation contract is the
# same one bootstrap/fleet relies on.
resource "terraform_data" "fleet_kv_preconditions" {
  input = { fleet_kv_id = local.fleet_kv_id }

  lifecycle {
    precondition {
      condition     = lower(local.derived.fleet_kv_resource_group) == lower(local.fleet_doc.acr.resource_group)
      error_message = "_fleet.yaml.keyvault.resource_group must equal acr.resource_group; the fleet KV is colocated with the ACR in the fleet-shared RG."
    }
  }
}

# --- RBAC for the Stage 0 executor -------------------------------------------
#
# Stage 0 runs as the `fleet-stage0` UAMI in CI (or the operator's OIDC
# identity locally). Grant it `Key Vault Secrets Officer` at vault scope
# so it can write rotated Argo OIDC client secrets.

data "azuread_client_config" "current" {}

resource "azapi_resource" "ra_stage0_kv_secrets_officer" {
  type      = "Microsoft.Authorization/roleAssignments@2022-04-01"
  name      = uuidv5("url", "stage0-kv-secrets-officer-${local.fleet_kv_id}")
  parent_id = local.fleet_kv_id

  body = {
    properties = {
      roleDefinitionId = "/subscriptions/${local.derived.acr_subscription_id}/providers/Microsoft.Authorization/roleDefinitions/${local.role_kv_secrets_officer}"
      principalId      = data.azuread_client_config.current.object_id
      principalType    = "ServicePrincipal"
    }
  }

  depends_on = [terraform_data.fleet_kv_preconditions]
}
