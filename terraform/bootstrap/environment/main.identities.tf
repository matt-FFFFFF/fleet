# main.identities.tf
#
# Per-env CI identity (uami-fleet-<env>) + GitHub OIDC FIC + RBAC.
#
# Also grants fleet-meta (created by bootstrap/fleet) the subscription-scope
# roles it needs in this env — these are env-scoped and therefore cannot
# live in bootstrap/fleet, which only knows about sub-fleet-shared.

locals {
  role_contributor     = "b24988ac-6180-42a0-ab88-20f7382dd24c"
  role_uaa             = "18d7d88d-d35e-4fb5-a5c3-7773c20a72d9"
  role_blob_data_ctrb  = "ba92f5b4-2d11-453d-a403-e96b0029c9fe"
  role_kv_secrets_user = "4633458b-17de-408a-b874-0445c86b69e6"

  # `AcrPull` built-in role definition GUID — used in the ABAC condition.
  role_acr_pull = "7f951dda-4ed3-4680-a7ca-43fe172d538d"

  env_sub_id = var.environment.subscription_id
}

# --- Env resource groups -----------------------------------------------------

resource "azapi_resource" "rg_env_shared" {
  type      = "Microsoft.Resources/resourceGroups@2024-03-01"
  name      = "rg-fleet-${var.env}-shared"
  parent_id = "/subscriptions/${local.env_sub_id}"
  location  = var.location
  body      = { properties = {} }
}

resource "azapi_resource" "rg_env_dns" {
  type      = "Microsoft.Resources/resourceGroups@2024-03-01"
  name      = replace(var.fleet.dns.resource_group_pattern, "{env}", var.env)
  parent_id = "/subscriptions/${local.env_sub_id}"
  location  = var.location
  body      = { properties = {} }
}

resource "azapi_resource" "rg_env_obs" {
  type      = "Microsoft.Resources/resourceGroups@2024-03-01"
  name      = "rg-obs-${var.env}"
  parent_id = "/subscriptions/${local.env_sub_id}"
  location  = var.location
  body      = { properties = {} }
}

# --- uami-fleet-<env> --------------------------------------------------------

resource "azapi_resource" "uami_env" {
  type      = "Microsoft.ManagedIdentity/userAssignedIdentities@2023-01-31"
  name      = "uami-fleet-${var.env}"
  parent_id = azapi_resource.rg_env_shared.id
  location  = var.location

  body                   = { properties = {} }
  response_export_values = ["properties.clientId", "properties.principalId"]
}

resource "azapi_resource" "fic_env" {
  type      = "Microsoft.ManagedIdentity/userAssignedIdentities/federatedIdentityCredentials@2023-01-31"
  name      = "gh-fleet-${var.env}"
  parent_id = azapi_resource.uami_env.id

  body = {
    properties = {
      issuer    = "https://token.actions.githubusercontent.com"
      subject   = "repo:${var.fleet.github_org}/${var.fleet_repo_name}:environment:fleet-${var.env}"
      audiences = ["api://AzureADTokenExchange"]
    }
  }
}

# --- Env RBAC for uami-fleet-<env> -------------------------------------------
#
# Contributor at subscription scope, Blob Data Contributor on the env's state
# container, Key Vault Secrets User on the fleet KV, and a carefully-bounded
# `User Access Administrator` on the fleet ACR (ABAC-constrained to delegate
# only the AcrPull role to ServicePrincipal principals — i.e. cluster kubelet
# identities).

resource "azapi_resource" "ra_env_sub_contrib" {
  type      = "Microsoft.Authorization/roleAssignments@2022-04-01"
  name      = uuidv5("url", "env-sub-contrib-${azapi_resource.uami_env.id}")
  parent_id = "/subscriptions/${local.env_sub_id}"

  body = {
    properties = {
      roleDefinitionId = "/subscriptions/${local.env_sub_id}/providers/Microsoft.Authorization/roleDefinitions/${local.role_contributor}"
      principalId      = azapi_resource.uami_env.output.properties.principalId
      principalType    = "ServicePrincipal"
    }
  }
}

resource "azapi_resource" "ra_env_blob_contrib" {
  type      = "Microsoft.Authorization/roleAssignments@2022-04-01"
  name      = uuidv5("url", "env-blob-${azapi_resource.uami_env.id}")
  parent_id = azapi_resource.state_container_env.id

  body = {
    properties = {
      roleDefinitionId = "/subscriptions/${var.fleet.state.subscription_id}/providers/Microsoft.Authorization/roleDefinitions/${local.role_blob_data_ctrb}"
      principalId      = azapi_resource.uami_env.output.properties.principalId
      principalType    = "ServicePrincipal"
    }
  }
}

# Fleet KV resource id — computed (KV created by Stage 0, same naming).
locals {
  fleet_kv_id = join("/", [
    "/subscriptions", var.fleet.acr.subscription_id,
    "resourceGroups", var.fleet.acr.resource_group,
    "providers/Microsoft.KeyVault/vaults", var.fleet.keyvault.name,
  ])
  fleet_acr_id = join("/", [
    "/subscriptions", var.fleet.acr.subscription_id,
    "resourceGroups", var.fleet.acr.resource_group,
    "providers/Microsoft.ContainerRegistry/registries", var.fleet.acr.name,
  ])
}

resource "azapi_resource" "ra_env_fleet_kv_secrets_user" {
  type      = "Microsoft.Authorization/roleAssignments@2022-04-01"
  name      = uuidv5("url", "env-fleet-kv-${azapi_resource.uami_env.id}")
  parent_id = local.fleet_kv_id

  body = {
    properties = {
      roleDefinitionId = "/subscriptions/${var.fleet.acr.subscription_id}/providers/Microsoft.Authorization/roleDefinitions/${local.role_kv_secrets_user}"
      principalId      = azapi_resource.uami_env.output.properties.principalId
      principalType    = "ServicePrincipal"
    }
  }
}

# ABAC-constrained UAA on the fleet ACR: only lets this UAMI assign
# `AcrPull` to a ServicePrincipal. See PLAN §4.1 for the condition text.
resource "azapi_resource" "ra_env_acr_uaa_bounded" {
  type      = "Microsoft.Authorization/roleAssignments@2022-04-01"
  name      = uuidv5("url", "env-acr-uaa-${azapi_resource.uami_env.id}")
  parent_id = local.fleet_acr_id

  body = {
    properties = {
      roleDefinitionId = "/subscriptions/${var.fleet.acr.subscription_id}/providers/Microsoft.Authorization/roleDefinitions/${local.role_uaa}"
      principalId      = azapi_resource.uami_env.output.properties.principalId
      principalType    = "ServicePrincipal"

      conditionVersion = "2.0"
      condition        = <<-COND
        (
          !(ActionMatches{'Microsoft.Authorization/roleAssignments/write'})
          AND
          !(ActionMatches{'Microsoft.Authorization/roleAssignments/delete'})
        )
        OR
        (
          @Request[Microsoft.Authorization/roleAssignments:RoleDefinitionId]
            ForAnyOfAnyValues:GuidEquals {${local.role_acr_pull}}
          AND
          @Request[Microsoft.Authorization/roleAssignments:PrincipalType]
            StringEqualsIgnoreCase 'ServicePrincipal'
        )
        OR
        (
          @Resource[Microsoft.Authorization/roleAssignments:RoleDefinitionId]
            ForAnyOfAnyValues:GuidEquals {${local.role_acr_pull}}
          AND
          @Resource[Microsoft.Authorization/roleAssignments:PrincipalType]
            StringEqualsIgnoreCase 'ServicePrincipal'
        )
      COND
    }
  }
}

# --- fleet-meta subscription-scope RBAC in this env --------------------------
#
# fleet-meta needs Contributor + User Access Administrator + Application
# Administrator (Entra-level, already granted in bootstrap/fleet) to run
# team-bootstrap and env-bootstrap again against this env.

variable "fleet_meta_principal_id" {
  description = "principalId of uami-fleet-meta (from bootstrap/fleet outputs)."
  type        = string
}

resource "azapi_resource" "ra_meta_sub_contrib" {
  type      = "Microsoft.Authorization/roleAssignments@2022-04-01"
  name      = uuidv5("url", "meta-sub-contrib-${local.env_sub_id}")
  parent_id = "/subscriptions/${local.env_sub_id}"

  body = {
    properties = {
      roleDefinitionId = "/subscriptions/${local.env_sub_id}/providers/Microsoft.Authorization/roleDefinitions/${local.role_contributor}"
      principalId      = var.fleet_meta_principal_id
      principalType    = "ServicePrincipal"
    }
  }
}

resource "azapi_resource" "ra_meta_sub_uaa" {
  type      = "Microsoft.Authorization/roleAssignments@2022-04-01"
  name      = uuidv5("url", "meta-sub-uaa-${local.env_sub_id}")
  parent_id = "/subscriptions/${local.env_sub_id}"

  body = {
    properties = {
      roleDefinitionId = "/subscriptions/${local.env_sub_id}/providers/Microsoft.Authorization/roleDefinitions/${local.role_uaa}"
      principalId      = var.fleet_meta_principal_id
      principalType    = "ServicePrincipal"
    }
  }
}
