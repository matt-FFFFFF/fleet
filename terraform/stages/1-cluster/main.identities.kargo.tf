# stages/1-cluster/main.identities.kargo.tf
#
# Fleet-wide Kargo UAMI — singleton, attached (via FIC) to the Kargo
# controller SA on the management cluster. Pre-refactor home:
# terraform/stages/0-fleet/main.identities.tf. Moved here (REFACTOR.md
# Step 4) so the mgmt cluster's Stage 1 owns the UAMI alongside the
# Kargo AAD app (main.aad.kargo.tf) and the Kargo OIDC password
# rotation (main.kv.tf). FIC binding the UAMI to the Kargo controller
# SA already lives in Stage 2 mgmt; unchanged.
#
# Role assignments on this UAMI:
#
#   AcrPull on the fleet ACR       — granted HERE (this stage)
#   AKS RBAC Reader on each workload AKS
#                                  — granted in each spoke cluster's
#                                    Stage 1 (main.rbac.tf), unchanged
#
# Parent RG: the mgmt cluster's resource group (`local.cluster.resource_group`),
# resolved by config-loader from `cluster.yaml`. Pre-refactor home was
# `rg-fleet-shared` (Stage 0 created it there for proximity to the
# fleet ACR); moving to the mgmt cluster RG keeps lifecycle aligned
# with the rest of the mgmt cluster's identities (`uami-eso`,
# `uami-external-dns`, …).

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
