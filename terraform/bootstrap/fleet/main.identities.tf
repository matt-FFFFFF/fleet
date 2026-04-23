# main.identities.tf
#
# Phase 1 scope for this file post-vendor-refactor:
#   * the fleet shared resource group (ACR, fleet KV, and fleet-stage0 /
#     fleet-meta UAMIs all live here),
#   * Azure role-GUID locals (used both here and in main.github.tf's
#     `identity_role_assignments` map),
#   * Microsoft Graph app-role assignments on `fleet-stage0` and
#     `fleet-meta` (the module cannot assign Entra roles).
#
# The fleet-stage0 + fleet-meta UAMIs, their federated credentials, and
# their Azure RBAC assignments are created by `module.fleet_repo` (see
# main.github.tf). The Graph app-role assignments here reference that
# module's environment outputs for the principal IDs.

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
#
# User Access Administrator (`18d7d88d-d35e-4fb5-a5c3-7773c20a72d9`) is not
# used in this stage; reintroduce when Stage 0 delegates RBAC assignments to
# the fleet-meta identity.

locals {
  role_contributor    = "b24988ac-6180-42a0-ab88-20f7382dd24c"
  role_blob_data_ctrb = "ba92f5b4-2d11-453d-a403-e96b0029c9fe"
}

# --- Microsoft Graph app-role assignments -----------------------------------
#
# `fleet-stage0` holds `Application.ReadWrite.OwnedBy` on the Microsoft
# Graph SP: scoped CRUD on any AAD application where the assignee is listed
# as an owner. Stage 0 creates the Argo + Kargo apps (auto-owning them on
# create), writes the Argo RP client-secret, and — via Stage 1 mgmt
# (`uami-fleet-mgmt`) and Stage 2 per-cluster (`uami-fleet-<env>`) — grants
# those peers owner-scoped access too. See `docs/adoption.md` and the F2
# entry in STATUS.md (item 14).
#
# `fleet-meta` holds `AppRoleAssignment.ReadWrite.All` on Graph: lets it
# create the per-env `azuread_app_role_assignment` resources inside
# `bootstrap/environment` (itself running under `uami-fleet-meta`). This
# role grants only the ability to assign/unassign app-roles on service
# principals — it does NOT grant the ability to CRUD applications, rotate
# secrets, or write FICs (those remain scoped to the app-owners list).
#
# Both grants require Entra tenant-admin consent on first apply, same as
# the directory-role assignment they replace; no regression in operator
# burden. See `docs/adoption.md §5.1`.

# Microsoft Graph service principal in this tenant. Required as the
# `resource_object_id` for every `azuread_app_role_assignment` below.
data "azuread_service_principal" "msgraph" {
  client_id = "00000003-0000-0000-c000-000000000000"
}

locals {
  # Graph app-role ids (stable across tenants).
  msgraph_role_application_readwrite_ownedby   = "18a4783c-866b-4cc7-a460-3d5e5662c884"
  msgraph_role_approleassignment_readwrite_all = "06b708a9-e830-4db3-a914-8e69da51d44f"
}

resource "azuread_app_role_assignment" "stage0_app_rw_owned_by" {
  app_role_id         = local.msgraph_role_application_readwrite_ownedby
  principal_object_id = module.fleet_repo.environments["stage0"].identity.principal_id
  resource_object_id  = data.azuread_service_principal.msgraph.object_id
}

resource "azuread_app_role_assignment" "meta_approle_rw_all" {
  app_role_id         = local.msgraph_role_approleassignment_readwrite_all
  principal_object_id = module.fleet_repo.environments["meta"].identity.principal_id
  resource_object_id  = data.azuread_service_principal.msgraph.object_id
}
