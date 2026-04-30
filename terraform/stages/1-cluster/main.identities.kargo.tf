# stages/1-cluster/main.identities.kargo.tf
#
# Fleet-wide Kargo UAMI — singleton, attached (via FIC) to the Kargo
# controller SA on the management cluster. Workload identity only;
# the Kargo AAD application registration itself lives in
# `bootstrap/fleet` (operator-applied, PLAN §4 Stage -1). FIC binding
# this UAMI to the Kargo controller SA lives in Stage 2 mgmt
# (needs the AKS OIDC issuer URL, which is a Stage 1 output).
#
# Role assignments on this UAMI:
#
#   AcrPull on the fleet ACR       — granted HERE (this stage)
#   AKS RBAC Reader on each workload AKS
#                                  — granted in each spoke cluster's
#                                    Stage 1 (main.rbac.tf), unchanged
#
# Parent RG: the mgmt cluster's resource group (`local.cluster.resource_group`),
# resolved by config-loader from `cluster.yaml`.

locals {
  kargo_uami_resource_group_id = "/subscriptions/${local.cluster.subscription_id}/resourceGroups/${local.cluster.resource_group}"
}

resource "azapi_resource" "uami_kargo_mgmt" {
  count = local.mgmt_role_cluster ? 1 : 0

  type      = "Microsoft.ManagedIdentity/userAssignedIdentities@2023-01-31"
  name      = "uami-kargo-mgmt"
  parent_id = local.kargo_uami_resource_group_id
  location  = local.cluster.region

  body                   = {}
  response_export_values = ["id", "properties.clientId", "properties.principalId"]
}

# Built-in role: AcrPull — defined in main.rbac.tf as `local.role_acr_pull`.

resource "azapi_resource" "ra_kargo_acrpull" {
  count = local.mgmt_role_cluster ? 1 : 0

  type      = "Microsoft.Authorization/roleAssignments@2022-04-01"
  name      = uuidv5("url", "kargo-acrpull-${var.acr_resource_id}")
  parent_id = var.acr_resource_id

  body = {
    properties = {
      roleDefinitionId = "/subscriptions/${local.cluster.subscription_id}/providers/Microsoft.Authorization/roleDefinitions/${local.role_acr_pull}"
      principalId      = azapi_resource.uami_kargo_mgmt[0].output.properties.principalId
      principalType    = "ServicePrincipal"
    }
  }

  lifecycle {
    precondition {
      condition     = var.acr_resource_id != null && var.acr_resource_id != ""
      error_message = "TF_VAR_acr_resource_id must be set on the management cluster (consumed by uami-kargo-mgmt's AcrPull on the fleet ACR). Published as the ACR_RESOURCE_ID repo variable by bootstrap/environment env=mgmt."
    }
  }
}
