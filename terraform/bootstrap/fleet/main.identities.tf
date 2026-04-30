# main.identities.tf
#
# Phase 1 scope for this file post-vendor-refactor:
#   * the fleet shared resource group (ACR, fleet KV, and the fleet-meta
#     UAMI all live here),
#   * Azure role-GUID locals (used both here and in main.github.tf's
#     `identity_role_assignments` map).
#
# The fleet-meta UAMI, its federated credentials, and its Azure RBAC
# assignments are created by `module.fleet_repo` (see main.github.tf).
#
# Microsoft Graph app-role assignments are NOT issued from this stage
# post-REFACTOR.md (Stage 0 deletion). The single Graph grant the fleet
# needs — `Application.ReadWrite.OwnedBy` on `uami-fleet-mgmt` for
# Stage 1 mgmt-cluster Argo + Kargo AAD app management — is issued
# manually by the operator after `bootstrap/environment` env=mgmt
# bootstraps the UAMI. See `docs/adoption.md §5.3`.

# --- Fleet shared resource group (for ACR / fleet KV / shared state) ---------

resource "azapi_resource" "rg_fleet_shared" {
  type      = "Microsoft.Resources/resourceGroups@2024-03-01"
  name      = local.derived.acr_resource_group
  parent_id = "/subscriptions/${local.derived.acr_subscription_id}"
  location  = local.derived.acr_location

  body = {}
}

# --- Azure RBAC role-definition GUIDs ---------------------------------------
#
# Built-in role GUIDs used by this stage + the env bootstrap stage.

locals {
  role_blob_data_ctrb = "ba92f5b4-2d11-453d-a403-e96b0029c9fe"
}
