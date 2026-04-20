# main.kv.tf
#
# Fleet Key Vault — exactly ONE per fleet, strictly private (PE-only).
#
# Stage ownership: bootstrap/fleet (Stage -1) owns KV creation so that
# the Stage -1 runner pool's Container App Job can reference the GH App
# PEM secret (`fleet-runners-app-pem`) at module-apply time. Stage 0
# consumes the existing KV (derived id, no data lookup) and (a) seeds
# additional fleet-wide secrets — `argocd-github-app-pem`,
# `argocd-oidc-client-secret`, GH App PEMs created by `init-gh-apps.sh`
# — and (b) holds `Key Vault Secrets Officer` for the Stage 0 executor
# so rotations can write new secret versions.
#
# Networking pattern mirrors the per-pool ACR:
#   - publicNetworkAccess = Disabled
#   - networkAcls.defaultAction = Deny, bypass = None
#   - Private endpoint on networking.fleet_kv.private_endpoint.subnet_id
#   - A-record registered in the operator-supplied central
#     privatelink.vaultcore.azure.net zone (BYO, typically in the hub
#     connectivity subscription; symmetric with
#     privatelink.blob.core.windows.net for tfstate and
#     privatelink.azurecr.io for the runner ACR).
#
# Consequence for operators: the `init-gh-apps.sh` helper that seeds the
# GH App PEM(s) into this KV must run from a host with private-network
# reach to the vault (e.g. a jump host in the hub, a VPN, or the fleet
# runners themselves after they are online). See docs/adoption.md §5.2.
#
# Soft-delete + purge protection are mandatory. RBAC authorization mode
# (no access policies) is mandatory.

resource "azapi_resource" "fleet_kv" {
  type      = "Microsoft.KeyVault/vaults@2023-07-01"
  name      = local.derived.fleet_kv_name
  parent_id = azapi_resource.rg_fleet_shared.id
  location  = local.derived.fleet_kv_location

  body = {
    properties = {
      tenantId                  = local.fleet.tenant_id
      sku                       = { family = "A", name = "standard" }
      enableRbacAuthorization   = true
      enablePurgeProtection     = true
      enableSoftDelete          = true
      softDeleteRetentionInDays = 90
      publicNetworkAccess       = "Disabled"
      networkAcls = {
        # bypass = None: Azure trusted services (Monitor, Backup, Policy)
        # must also traverse the PE; there is no "azure services" escape
        # hatch. Symmetric with the tfstate SA.
        bypass              = "None"
        defaultAction       = "Deny"
        ipRules             = []
        virtualNetworkRules = []
      }
    }
  }

  response_export_values = ["id", "properties.vaultUri"]
}

# --- Private endpoint --------------------------------------------------------
#
# Lands in the mgmt VNet's `snet-pe-shared` subnet (repo-owned, created by
# main.network.tf via the sub-vending module; PLAN §3.4). A-record
# registers in the adopter-owned central `privatelink.vaultcore.azure.net`
# zone from `networking.private_dns_zones.vaultcore`.

resource "azapi_resource" "fleet_kv_pe" {
  type      = "Microsoft.Network/privateEndpoints@2023-11-01"
  name      = "pe-${local.derived.fleet_kv_name}-vault"
  parent_id = azapi_resource.rg_fleet_shared.id
  location  = local.derived.fleet_kv_location

  body = {
    properties = {
      subnet = {
        id = local.snet_pe_shared_id
      }
      privateLinkServiceConnections = [
        {
          name = "plsc-${local.derived.fleet_kv_name}-vault"
          properties = {
            privateLinkServiceId = azapi_resource.fleet_kv.output.id
            groupIds             = ["vault"]
          }
        }
      ]
    }
  }

  response_export_values = ["id"]
}

resource "azapi_resource" "fleet_kv_pe_dns_zone_group" {
  type      = "Microsoft.Network/privateEndpoints/privateDnsZoneGroups@2023-11-01"
  name      = "default"
  parent_id = azapi_resource.fleet_kv_pe.id

  body = {
    properties = {
      privateDnsZoneConfigs = [
        {
          name = "privatelink-vaultcore-azure-net"
          properties = {
            privateDnsZoneId = local.networking_central.pdz_vaultcore
          }
        }
      ]
    }
  }
}

# --- RBAC: runner UAMI -> Key Vault Secrets User -----------------------------
#
# uami-fleet-runners must read `fleet-runners-app-pem` at runner-start time
# (ACA resolves the KV reference via the UAMI attached to the Container App
# Job). Built-in role guid:
#   Key Vault Secrets User  4633458b-17de-4321-8a42-03b4c0a0ebb2
#
# Issued at KV scope from this stage — the KV now exists in the same state
# graph as the UAMI, so the PUT succeeds in a single apply.

locals {
  role_kv_secrets_user_guid = "4633458b-17de-4321-8a42-03b4c0a0ebb2"
}

resource "azapi_resource" "ra_runner_kv_secrets_user" {
  type      = "Microsoft.Authorization/roleAssignments@2022-04-01"
  name      = uuidv5("url", "fleet-runners-kv-secrets-user-${azapi_resource.fleet_kv.output.id}")
  parent_id = azapi_resource.fleet_kv.output.id

  body = {
    properties = {
      roleDefinitionId = "/subscriptions/${local.derived.acr_subscription_id}/providers/Microsoft.Authorization/roleDefinitions/${local.role_kv_secrets_user_guid}"
      principalId      = azapi_resource.runner_uami.output.properties.principalId
      principalType    = "ServicePrincipal"
    }
  }
}

output "fleet_kv_id" {
  description = "Resource id of the fleet Key Vault."
  value       = azapi_resource.fleet_kv.output.id
}

output "fleet_kv_vault_uri" {
  description = "Data-plane URI of the fleet Key Vault (https://<name>.vault.azure.net/)."
  value       = azapi_resource.fleet_kv.output.properties.vaultUri
}
