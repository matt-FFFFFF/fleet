# main.identities.tf
#
# fleet-stage0 and fleet-meta UAMIs + their federated credentials.
#
# RBAC assignments here are scoped deliberately; any expansion must match the
# matrix in PLAN §4 / §10. Azure AD app-admin roles are assigned via
# azuread_directory_role_assignment (below) — not `azapi` — because they're
# Entra-directory assignments, not ARM role assignments.

# --- Fleet shared resource group (for ACR / fleet KV / shared state) ---------

resource "azapi_resource" "rg_fleet_shared" {
  type      = "Microsoft.Resources/resourceGroups@2024-03-01"
  name      = local.derived.acr_resource_group
  parent_id = "/subscriptions/${local.derived.acr_subscription_id}"
  location  = local.derived.acr_location

  body = {}
}

# --- UAMIs -------------------------------------------------------------------

resource "azapi_resource" "uami_fleet_stage0" {
  type      = "Microsoft.ManagedIdentity/userAssignedIdentities@2023-01-31"
  name      = "uami-fleet-stage0"
  parent_id = azapi_resource.rg_fleet_shared.id
  location  = local.derived.acr_location

  body                   = {}
  response_export_values = ["properties.clientId", "properties.principalId"]
}

resource "azapi_resource" "uami_fleet_meta" {
  type      = "Microsoft.ManagedIdentity/userAssignedIdentities@2023-01-31"
  name      = "uami-fleet-meta"
  parent_id = azapi_resource.rg_fleet_shared.id
  location  = local.derived.acr_location

  body                   = {}
  response_export_values = ["properties.clientId", "properties.principalId"]
}

# --- GitHub-OIDC federated credentials --------------------------------------

resource "azapi_resource" "fic_stage0" {
  type      = "Microsoft.ManagedIdentity/userAssignedIdentities/federatedIdentityCredentials@2023-01-31"
  name      = "gh-fleet-stage0"
  parent_id = azapi_resource.uami_fleet_stage0.id

  body = {
    properties = {
      issuer    = "https://token.actions.githubusercontent.com"
      subject   = local.derived.fleet_stage0_fic_subject
      audiences = ["api://AzureADTokenExchange"]
    }
  }
}

resource "azapi_resource" "fic_meta" {
  type      = "Microsoft.ManagedIdentity/userAssignedIdentities/federatedIdentityCredentials@2023-01-31"
  name      = "gh-fleet-meta"
  parent_id = azapi_resource.uami_fleet_meta.id

  body = {
    properties = {
      issuer    = "https://token.actions.githubusercontent.com"
      subject   = local.derived.fleet_meta_fic_subject
      audiences = ["api://AzureADTokenExchange"]
    }
  }
}

# --- Azure RBAC assignments -------------------------------------------------
#
# Built-in role GUIDs (subscription-scope resource IDs):
#   Contributor                          b24988ac-6180-42a0-ab88-20f7382dd24c
#   Storage Blob Data Contributor        ba92f5b4-2d11-453d-a403-e96b0029c9fe
#
# User Access Administrator (18d7d88d-d35e-4fb5-a5c3-7773c20a72d9) is not
# used by bootstrap/fleet; reintroduce when Stage 0 starts delegating RBAC
# assignments to the fleet-meta identity.

locals {
  role_contributor    = "b24988ac-6180-42a0-ab88-20f7382dd24c"
  role_blob_data_ctrb = "ba92f5b4-2d11-453d-a403-e96b0029c9fe"
}

# fleet-stage0: Contributor on rg-fleet-shared
resource "azapi_resource" "ra_stage0_rg_contrib" {
  type      = "Microsoft.Authorization/roleAssignments@2022-04-01"
  name      = uuidv5("url", "stage0-rg-contrib-${azapi_resource.uami_fleet_stage0.id}")
  parent_id = azapi_resource.rg_fleet_shared.id

  body = {
    properties = {
      roleDefinitionId = "/subscriptions/${local.derived.acr_subscription_id}/providers/Microsoft.Authorization/roleDefinitions/${local.role_contributor}"
      principalId      = azapi_resource.uami_fleet_stage0.output.properties.principalId
      principalType    = "ServicePrincipal"
    }
  }
}

# fleet-stage0: Storage Blob Data Contributor on tfstate-fleet container
resource "azapi_resource" "ra_stage0_blob_contrib" {
  type      = "Microsoft.Authorization/roleAssignments@2022-04-01"
  name      = uuidv5("url", "stage0-blob-${azapi_resource.uami_fleet_stage0.id}")
  parent_id = azapi_resource.state_container_fleet.id

  body = {
    properties = {
      roleDefinitionId = "/subscriptions/${local.derived.state_subscription}/providers/Microsoft.Authorization/roleDefinitions/${local.role_blob_data_ctrb}"
      principalId      = azapi_resource.uami_fleet_stage0.output.properties.principalId
      principalType    = "ServicePrincipal"
    }
  }
}

# fleet-meta: Storage Blob Data Contributor on tfstate-fleet container
resource "azapi_resource" "ra_meta_blob_contrib" {
  type      = "Microsoft.Authorization/roleAssignments@2022-04-01"
  name      = uuidv5("url", "meta-blob-${azapi_resource.uami_fleet_meta.id}")
  parent_id = azapi_resource.state_container_fleet.id

  body = {
    properties = {
      roleDefinitionId = "/subscriptions/${local.derived.state_subscription}/providers/Microsoft.Authorization/roleDefinitions/${local.role_blob_data_ctrb}"
      principalId      = azapi_resource.uami_fleet_meta.output.properties.principalId
      principalType    = "ServicePrincipal"
    }
  }
}

# fleet-meta: subscription-scope RBAC is handled by bootstrap/environment
# (one apply per env subscription) — see that module for UAA + Contributor.

# --- Entra directory role assignments ---------------------------------------
#
# Both UAMIs need `Application Administrator` in Entra to CRUD AAD apps
# (Stage 0 for fleet-stage0; env/team bootstrap flows for fleet-meta).

data "azuread_directory_role_templates" "all" {
}

resource "azuread_directory_role" "app_admin" {
  template_id = one([
    for tmpl in data.azuread_directory_role_templates.all.role_templates : tmpl.object_id if tmpl.display_name == "Application Administrator"
  ])
}

resource "azuread_directory_role_assignment" "stage0_app_admin" {
  role_id             = azuread_directory_role.app_admin.object_id
  principal_object_id = azapi_resource.uami_fleet_stage0.output.properties.principalId
}

resource "azuread_directory_role_assignment" "meta_app_admin" {
  role_id             = azuread_directory_role.app_admin.object_id
  principal_object_id = azapi_resource.uami_fleet_meta.output.properties.principalId
}
