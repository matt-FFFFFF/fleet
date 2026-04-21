# main.acr.tf
#
# Single fleet-wide Azure Container Registry. Hosts every team's images as
# `<acr>.azurecr.io/<team>/<image>` plus shared Helm OCI charts at
# `<acr>.azurecr.io/helm/<chart>`.
#
# Premium SKU — required for geo-replication and private-link; Helm OCI and
# ABAC repo permissions also require Premium.
#
# Per-cluster kubelet identities are granted `AcrPull` in each cluster's
# Stage 1 (condition-constrained via the fleet-<env> UAMI). The ACR resource
# id flows to Stage 1 via the `ACR_RESOURCE_ID` repo variable.
#
# Private from the first apply (PLAN §3.4): `publicNetworkAccess =
# Disabled` + a private endpoint in the mgmt VNet's `snet-pe-fleet` subnet
# (co-located with `acr.location` via same-region-else-first). A-record
# registers in the adopter-owned central `privatelink.azurecr.io` zone
# from `networking.private_dns_zones.azurecr`.
#
# `rg-fleet-shared` is created by bootstrap/fleet; referenced by id.

resource "azapi_resource" "acr" {
  # Preview API version is required: `softDeletePolicy`,
  # `azureADAuthenticationAsArmPolicy`, and `anonymousPullEnabled` are not
  # exposed in stable schemas as of azapi 2.9. Re-evaluate when the
  # 2024-xx-xx stable api-version that absorbs these graduates.
  type      = "Microsoft.ContainerRegistry/registries@2023-11-01-preview"
  name      = local.derived.acr_name
  parent_id = local.derived.fleet_shared_rg_id
  location  = local.derived.acr_location

  body = {
    sku = { name = local.derived.acr_sku }
    properties = {
      adminUserEnabled     = false
      anonymousPullEnabled = false
      # Private from day one — all pulls flow through the PE below, which
      # registers in the central privatelink.azurecr.io zone. Data-plane
      # reach from runners / AKS kubelets relies on the mgmt VNet
      # ↔ spoke peerings authored by bootstrap/fleet + bootstrap/environment
      # and the central PDZ's VNet links (owned by the adopter).
      publicNetworkAccess = "Disabled"
      zoneRedundancy      = "Enabled"
      # Policies
      policies = {
        quarantinePolicy                 = { status = "disabled" }
        trustPolicy                      = { type = "Notary", status = "disabled" }
        retentionPolicy                  = { days = 30, status = "enabled" }
        exportPolicy                     = { status = "enabled" }
        azureADAuthenticationAsArmPolicy = { status = "enabled" }
        softDeletePolicy                 = { retentionDays = 7, status = "enabled" }
      }
    }
  }

  response_export_values = ["id", "properties.loginServer"]
}

# -----------------------------------------------------------------------------
# Private endpoint for the fleet ACR. Lands in the `snet-pe-fleet` subnet of
# the mgmt VNet in `local.acr_mgmt_region` (the mgmt region co-located with
# the ACR via `acr.location`, with same-region-else-first fallback). The
# precondition surfaces a mismatch before the PE is created.
# -----------------------------------------------------------------------------

resource "azapi_resource" "acr_pe" {
  type      = "Microsoft.Network/privateEndpoints@2023-11-01"
  name      = "pe-${local.derived.acr_name}-registry"
  parent_id = local.derived.fleet_shared_rg_id
  location  = local.derived.acr_location

  body = {
    properties = {
      subnet = {
        id = var.mgmt_pe_fleet_subnet_ids[local.acr_mgmt_region]
      }
      privateLinkServiceConnections = [
        {
          name = "plsc-${local.derived.acr_name}-registry"
          properties = {
            privateLinkServiceId = azapi_resource.acr.output.id
            groupIds             = ["registry"]
          }
        }
      ]
    }
  }

  lifecycle {
    precondition {
      condition     = contains(keys(var.mgmt_pe_fleet_subnet_ids), local.derived.acr_location)
      error_message = "clusters/_fleet.yaml: no networking.envs.mgmt.regions.<region> entry matches the fleet ACR location (`acr.location` = ${local.derived.acr_location}); the fleet ACR PE cannot land in a co-located mgmt VNet. Add a mgmt region in that location, or change `acr.location`."
    }
    precondition {
      condition     = local.pdz_azurecr != null && can(regex("^/subscriptions/[0-9a-fA-F-]{36}/resourceGroups/[^/]+/providers/Microsoft\\.Network/privateDnsZones/privatelink\\.azurecr\\.io$", local.pdz_azurecr))
      error_message = "clusters/_fleet.yaml: networking.private_dns_zones.azurecr must be a full ARM resource id ending in `/providers/Microsoft.Network/privateDnsZones/privatelink.azurecr.io`. See docs/adoption.md §5.1."
    }
  }

  response_export_values = ["id"]
}

resource "azapi_resource" "acr_pe_dns_zone_group" {
  type      = "Microsoft.Network/privateEndpoints/privateDnsZoneGroups@2023-11-01"
  name      = "default"
  parent_id = azapi_resource.acr_pe.id

  body = {
    properties = {
      privateDnsZoneConfigs = [
        {
          name = "privatelink-azurecr-io"
          properties = {
            privateDnsZoneId = local.pdz_azurecr
          }
        }
      ]
    }
  }
}
