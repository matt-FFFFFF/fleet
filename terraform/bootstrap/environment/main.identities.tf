# main.identities.tf
#
# Env-scope scaffolding that is NOT tied to the per-env GitHub environment
# UAMI (that lives in main.github.tf, inside `module.env_github`):
#
#   * env resource groups (shared / DNS / observability),
#   * Azure role-GUID + scope-ID locals used by main.github.tf's
#     `module.env_github.role_assignments`,
#   * `fleet-meta` subscription-scope role assignments (this env's
#     subscription), wired against the principal ID provided as
#     `var.fleet_meta_principal_id` from bootstrap/fleet.

locals {
  role_contributor     = "b24988ac-6180-42a0-ab88-20f7382dd24c"
  role_uaa             = "18d7d88d-d35e-4fb5-a5c3-7773c20a72d9"
  role_blob_data_ctrb  = "ba92f5b4-2d11-453d-a403-e96b0029c9fe"
  role_kv_secrets_user = "4633458b-17de-408a-b874-0445c86b69e6"

  # `AcrPull` built-in role definition GUID — used in the ABAC condition on
  # `module.env_github.role_assignments.acr_uaa_bounded`.
  role_acr_pull = "7f951dda-4ed3-4680-a7ca-43fe172d538d"

  env_sub_id = local.environment.subscription_id

  # Fleet KV + ACR resource IDs — computed; KV/ACR themselves are created by
  # Stage 0, same naming derivation as docs/naming.md.
  fleet_kv_id = join("/", [
    "/subscriptions", local.derived.acr_subscription_id,
    "resourceGroups", local.derived.acr_resource_group,
    "providers/Microsoft.KeyVault/vaults", local.derived.fleet_kv_name,
  ])
  fleet_acr_id = join("/", [
    "/subscriptions", local.derived.acr_subscription_id,
    "resourceGroups", local.derived.acr_resource_group,
    "providers/Microsoft.ContainerRegistry/registries", local.derived.acr_name,
  ])
}

# --- Env resource groups -----------------------------------------------------

resource "azapi_resource" "rg_env_shared" {
  type      = "Microsoft.Resources/resourceGroups@2024-03-01"
  name      = "rg-fleet-${var.env}-shared"
  parent_id = "/subscriptions/${local.env_sub_id}"
  location  = local.location
  body      = { properties = {} }
}

resource "azapi_resource" "rg_env_dns" {
  type      = "Microsoft.Resources/resourceGroups@2024-03-01"
  name      = replace(local.dns.resource_group_pattern, "{env}", var.env)
  parent_id = "/subscriptions/${local.env_sub_id}"
  location  = local.location
  body      = {}
}

resource "azapi_resource" "rg_env_obs" {
  type      = "Microsoft.Resources/resourceGroups@2024-03-01"
  name      = "rg-obs-${var.env}"
  parent_id = "/subscriptions/${local.env_sub_id}"
  location  = local.location
  body      = {}
}

# --- fleet-meta subscription-scope RBAC in this env --------------------------
#
# fleet-meta (created by bootstrap/fleet, not owned by this stage) needs
# Contributor + User Access Administrator + Application Administrator
# (Entra-level, granted in bootstrap/fleet) to run team-bootstrap and
# env-bootstrap again against this env.

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
