# main.identities.tf
#
# Phase 1 scope for this file post-vendor-refactor:
#   * the fleet shared resource group (ACR, fleet KV, and fleet-stage0 /
#     fleet-meta UAMIs all live here),
#   * Azure role-GUID locals (used both here and in main.github.tf's
#     `identity_role_assignments` map),
#   * Entra directory role assignments (the module cannot assign Entra roles).
#
# The fleet-stage0 + fleet-meta UAMIs, their federated credentials, and
# their Azure RBAC assignments are created by `module.fleet_repo` (see
# main.github.tf). The Entra role assignments here reference that module's
# environment outputs for the principal IDs.

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

# --- Entra directory role assignments ---------------------------------------
#
# Both UAMIs need `Application Administrator` in Entra to CRUD AAD apps
# (Stage 0 uses fleet-stage0; env/team bootstrap flows use fleet-meta).
# The Entra role assignments reference the module-created UAMIs via the
# `environments["<key>"].identity.principal_id` outputs.

data "azuread_directory_role_templates" "all" {
}

resource "azuread_directory_role" "app_admin" {
  template_id = one([
    for tmpl in data.azuread_directory_role_templates.all.role_templates :
    tmpl.object_id if tmpl.display_name == "Application Administrator"
  ])
}

resource "azuread_directory_role_assignment" "stage0_app_admin" {
  role_id             = azuread_directory_role.app_admin.object_id
  principal_object_id = module.fleet_repo.environments["stage0"].identity.principal_id
}

resource "azuread_directory_role_assignment" "meta_app_admin" {
  role_id             = azuread_directory_role.app_admin.object_id
  principal_object_id = module.fleet_repo.environments["meta"].identity.principal_id
}
