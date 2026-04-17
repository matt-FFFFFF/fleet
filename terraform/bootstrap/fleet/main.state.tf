# main.state.tf
#
# Creates the fleet-wide Terraform state storage. All downstream stages —
# Stage 0, bootstrap/environment, bootstrap/team, and the per-env Stage 1 /
# Stage 2 containers seeded by bootstrap/environment — land in this account.
#
# Resource scope: the shared subscription (var.fleet.state.subscription_id).
# This is sub-fleet-shared in the current subscription model.

resource "azapi_resource" "state_rg" {
  type      = "Microsoft.Resources/resourceGroups@2024-03-01"
  name      = var.fleet.state.resource_group
  parent_id = "/subscriptions/${var.fleet.state.subscription_id}"
  location  = var.fleet.acr.location # colocate state with fleet shared infra

  body = {
    properties = {}
  }
}

resource "azapi_resource" "state_sa" {
  type      = "Microsoft.Storage/storageAccounts@2023-05-01"
  name      = var.fleet.state.storage_account
  parent_id = azapi_resource.state_rg.id
  location  = var.fleet.acr.location

  body = {
    sku  = { name = "Standard_ZRS" }
    kind = "StorageV2"
    properties = {
      accessTier                   = "Hot"
      allowBlobPublicAccess        = false
      allowSharedKeyAccess         = false # OIDC + RBAC only; no shared-key listings in CI
      minimumTlsVersion            = "TLS1_2"
      supportsHttpsTrafficOnly     = true
      publicNetworkAccess          = "Enabled" # TODO: flip to Disabled + PE once hub is online
      defaultToOAuthAuthentication = true
      encryption = {
        services = {
          blob  = { enabled = true, keyType = "Account" }
          file  = { enabled = true, keyType = "Account" }
          queue = { enabled = true, keyType = "Account" }
          table = { enabled = true, keyType = "Account" }
        }
        keySource = "Microsoft.Storage"
      }
    }
  }

  response_export_values = ["id", "properties.primaryEndpoints.blob"]
}

resource "azapi_resource" "state_blob_service" {
  type      = "Microsoft.Storage/storageAccounts/blobServices@2023-05-01"
  name      = "default"
  parent_id = azapi_resource.state_sa.id

  body = {
    properties = {
      isVersioningEnabled = true
      deleteRetentionPolicy = {
        enabled = true
        days    = 30
      }
      containerDeleteRetentionPolicy = {
        enabled = true
        days    = 30
      }
    }
  }
}

resource "azapi_resource" "state_container_fleet" {
  type      = "Microsoft.Storage/storageAccounts/blobServices/containers@2023-05-01"
  name      = var.fleet.state.containers.fleet
  parent_id = azapi_resource.state_blob_service.id

  body = {
    properties = {
      publicAccess = "None"
    }
  }
}
