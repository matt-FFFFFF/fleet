# main.kv.tf
#
# Fleet Key Vault — exactly ONE per fleet, and it stores ONLY secrets that
# must be read by more than one cluster. Current tenants:
#
#   argocd-github-app-pem       — every cluster's Argo reads it
#   argocd-oidc-client-secret   — every cluster's Argo reads it
#                                 (rotated here on every Stage 0 apply, 60d
#                                  cadence; see main.aad.tf)
#
# Mgmt-only secrets (kargo-github-app-pem, kargo-oidc-client-secret) live
# in the mgmt cluster's own KV (Stage 1), not here. Per-cluster secrets
# live in each cluster's own KV (Stage 1).
#
# Soft-delete + purge protection are mandatory. RBAC authorization mode
# (no access policies) is mandatory.

resource "azapi_resource" "fleet_kv" {
  type      = "Microsoft.KeyVault/vaults@2023-07-01"
  name      = local.derived.fleet_kv_name
  parent_id = local.derived.fleet_shared_rg_id
  location  = local.derived.fleet_kv_location

  body = {
    properties = {
      tenantId                  = local.fleet.tenant_id
      sku                       = { family = "A", name = "standard" }
      enableRbacAuthorization   = true
      enablePurgeProtection     = true
      enableSoftDelete          = true
      softDeleteRetentionInDays = 90
      publicNetworkAccess       = "Enabled" # TODO: PE + Disabled once hub is online
      networkAcls = {
        bypass        = "AzureServices"
        defaultAction = "Allow"
      }
    }
  }

  response_export_values = ["id", "properties.vaultUri"]

  # The fleet KV must live in the same RG as the ACR (rg-fleet-shared) so
  # bootstrap/environment can reconstruct its id from acr.* alone. Surface
  # any drift in `_fleet.yaml.keyvault.resource_group` early instead of
  # letting Stage 0 silently ignore the field.
  lifecycle {
    precondition {
      condition     = lower(local.derived.fleet_kv_resource_group) == lower(local.fleet_doc.acr.resource_group)
      error_message = "_fleet.yaml.keyvault.resource_group must equal acr.resource_group; the fleet KV is colocated with the ACR in the fleet-shared RG."
    }
  }
}

# --- RBAC for the Stage 0 executor -------------------------------------------
#
# Stage 0 runs as the `fleet-stage0` UAMI (bootstrap/fleet). It needs
# `Key Vault Secrets Officer` on the fleet KV so it can write the rotated
# Argo OIDC client secret as a secret version. Built-in role guid:
#   Key Vault Secrets Officer  b86a8fe4-44ce-4948-aee5-eccb2c155cd7

data "azuread_client_config" "current" {}

locals {
  role_kv_secrets_officer = "b86a8fe4-44ce-4948-aee5-eccb2c155cd7"
}

resource "azapi_resource" "ra_stage0_kv_secrets_officer" {
  type      = "Microsoft.Authorization/roleAssignments@2022-04-01"
  name      = uuidv5("url", "stage0-kv-secrets-officer-${azapi_resource.fleet_kv.id}")
  parent_id = azapi_resource.fleet_kv.id

  body = {
    properties = {
      roleDefinitionId = "/subscriptions/${local.derived.acr_subscription_id}/providers/Microsoft.Authorization/roleDefinitions/${local.role_kv_secrets_officer}"
      principalId      = data.azuread_client_config.current.object_id
      principalType    = "ServicePrincipal"
    }
  }
}

# Data-plane role propagation typically completes within ~30s; buffer here
# avoids racing the first secret write on cold runs.
resource "time_sleep" "wait_kv_rbac" {
  depends_on      = [azapi_resource.ra_stage0_kv_secrets_officer]
  create_duration = "60s"

  # Re-run the delay if the role assignment is ever replaced
  # (e.g. principal drift), so secret writes don't race RBAC
  # propagation on re-apply.
  lifecycle {
    replace_triggered_by = [azapi_resource.ra_stage0_kv_secrets_officer]
  }
}
