# main.state.tf
#
# Creates the fleet-wide Terraform state storage. All downstream stages —
# Stage 0, bootstrap/environment, bootstrap/team, and the per-env Stage 1 /
# Stage 2 containers seeded by bootstrap/environment — land in this account.
#
# Resource scope: the shared subscription (fleet.state.subscription_id).

resource "azapi_resource" "state_rg" {
  type      = "Microsoft.Resources/resourceGroups@2024-03-01"
  name      = local.derived.state_resource_group
  parent_id = "/subscriptions/${local.derived.state_subscription}"
  location  = local.derived.acr_location # colocate state with fleet shared infra

  body = {
    properties = {}
  }
}

resource "azapi_resource" "state_sa" {
  type      = "Microsoft.Storage/storageAccounts@2023-05-01"
  name      = local.derived.state_storage_account
  parent_id = azapi_resource.state_rg.id
  location  = local.derived.acr_location

  body = {
    sku  = { name = "Standard_ZRS" }
    kind = "StorageV2"
    properties = {
      accessTier                   = "Hot"
      allowBlobPublicAccess        = false
      allowSharedKeyAccess         = false # OIDC + RBAC only; no shared-key listings in CI
      minimumTlsVersion            = "TLS1_2"
      supportsHttpsTrafficOnly     = true
      publicNetworkAccess          = var.allow_public_state_during_bootstrap ? "Enabled" : "Disabled"
      defaultToOAuthAuthentication = true
      networkAcls = {
        # Deny-by-default even while publicNetworkAccess is transiently
        # "Enabled" for the first apply; access always flows through the
        # private endpoint seeded below. bypass = "None" is deliberate —
        # we do not want Azure trusted services (including Azure Monitor,
        # Backup, Policy) reaching the SA via its public endpoint even
        # during the first-apply escape hatch window.
        bypass              = "None"
        defaultAction       = "Deny"
        ipRules             = []
        virtualNetworkRules = []
      }
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
  name      = local.derived.state_container
  parent_id = azapi_resource.state_blob_service.id

  body = {
    properties = {
      publicAccess = "None"
    }
  }
}

# -----------------------------------------------------------------------------
# Private endpoint for the blob sub-resource of the tfstate storage account.
# The PE lands in the `snet-pe-fleet` subnet of the mgmt VNet in the
# `state_mgmt_region` (the mgmt region co-located with the state SA via
# `local.derived.acr_location`). If no mgmt region matches the state
# SA's location, we fall back to the first mgmt region — the precondition
# below surfaces a clear error before any PE is created.
# The A-record registers in the adopter-owned central
# `privatelink.blob.core.windows.net` zone from
# `networking.private_dns_zones.blob`.
# -----------------------------------------------------------------------------

locals {
  # State SA is co-located with the fleet shared RG (acr_location).
  # Pick the mgmt region whose location matches; fall back to the first
  # mgmt region otherwise (the precondition on state_pe surfaces the
  # mismatch early).
  state_mgmt_region = contains(keys(local.mgmt_vnet_ids), local.derived.acr_location) ? (
    local.derived.acr_location
  ) : keys(local.mgmt_vnet_ids)[0]
}

resource "azapi_resource" "state_pe" {
  type      = "Microsoft.Network/privateEndpoints@2023-11-01"
  name      = "pe-${local.derived.state_storage_account}-blob"
  parent_id = azapi_resource.state_rg.id
  location  = local.derived.acr_location

  body = {
    properties = {
      subnet = {
        id = local.mgmt_snet_pe_fleet_ids[local.state_mgmt_region]
      }
      privateLinkServiceConnections = [
        {
          name = "plsc-${local.derived.state_storage_account}-blob"
          properties = {
            privateLinkServiceId = azapi_resource.state_sa.output.id
            groupIds             = ["blob"]
          }
        }
      ]
    }
  }

  lifecycle {
    precondition {
      condition     = contains(keys(local.mgmt_vnet_ids), local.derived.acr_location)
      error_message = "clusters/_fleet.yaml: no networking.envs.mgmt.regions.<region> entry matches the fleet shared location (`acr.location` = ${local.derived.acr_location}); the tfstate SA PE cannot land in a co-located mgmt VNet. Add a mgmt region in that location, or change `acr.location`."
    }
  }

  response_export_values = ["id"]
}

resource "azapi_resource" "state_pe_dns_zone_group" {
  type      = "Microsoft.Network/privateEndpoints/privateDnsZoneGroups@2023-11-01"
  name      = "default"
  parent_id = azapi_resource.state_pe.id

  body = {
    properties = {
      privateDnsZoneConfigs = [
        {
          name = "privatelink-blob-core-windows-net"
          properties = {
            privateDnsZoneId = local.networking_central.pdz_blob
          }
        }
      ]
    }
  }
}
