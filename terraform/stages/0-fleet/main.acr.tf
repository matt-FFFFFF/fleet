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
# `rg-fleet-shared` is created by bootstrap/fleet; referenced by id.

resource "azapi_resource" "acr" {
  type      = "Microsoft.ContainerRegistry/registries@2023-11-01-preview"
  name      = local.derived.acr_name
  parent_id = local.derived.fleet_shared_rg_id
  location  = local.derived.acr_location

  body = {
    sku = { name = local.derived.acr_sku }
    properties = {
      adminUserEnabled     = false
      anonymousPullEnabled = false
      publicNetworkAccess  = "Enabled" # TODO: flip to Disabled + PE once hub is online
      zoneRedundancy       = "Enabled"
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
