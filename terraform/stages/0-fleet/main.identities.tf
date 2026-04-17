# main.identities.tf
#
# Fleet-wide Kargo UAMI — singleton, attached (via FIC) to the Kargo
# controller SA on the management cluster only. Lives in Stage 0 so that
# its `principalId` propagates via the standard Stage 0 → repo-variable
# publish path, and every workload cluster's Stage 1 can consume it to
# grant `AKS RBAC Reader` to Kargo on the workload AKS.
#
# Role assignments on this UAMI:
#
#   AcrPull on the fleet ACR       — granted HERE (Stage 0 scope)
#   AKS RBAC Reader on each workload AKS
#                                  — granted in each workload cluster's
#                                    Stage 1 (not here)
#
# The FIC binding this UAMI to `system:serviceaccount:kargo:kargo-controller`
# is created by the mgmt cluster's Stage 2 (needs the mgmt AKS OIDC issuer
# URL, which Stage 1 outputs).

resource "azapi_resource" "uami_kargo_mgmt" {
  type      = "Microsoft.ManagedIdentity/userAssignedIdentities@2023-01-31"
  name      = "uami-kargo-mgmt"
  parent_id = local.derived.fleet_shared_rg_id
  location  = local.derived.acr_location

  body                   = {}
  response_export_values = ["id", "properties.clientId", "properties.principalId"]
}

# Built-in role: AcrPull
locals {
  role_acr_pull = "7f951dda-4ed3-4680-a7ca-43fe172d538d"
}

resource "azapi_resource" "ra_kargo_acrpull" {
  type      = "Microsoft.Authorization/roleAssignments@2022-04-01"
  name      = uuidv5("url", "kargo-acrpull-${azapi_resource.acr.id}")
  parent_id = azapi_resource.acr.id

  body = {
    properties = {
      roleDefinitionId = "/subscriptions/${local.derived.acr_subscription_id}/providers/Microsoft.Authorization/roleDefinitions/${local.role_acr_pull}"
      principalId      = azapi_resource.uami_kargo_mgmt.output.properties.principalId
      principalType    = "ServicePrincipal"
    }
  }
}
