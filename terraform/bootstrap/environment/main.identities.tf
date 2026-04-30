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
  role_rbac_admin      = "f58310d9-a9f6-439a-9e8d-f62e7b41a168"
  role_blob_data_ctrb  = "ba92f5b4-2d11-453d-a403-e96b0029c9fe"
  role_kv_secrets_user = "4633458b-17de-408a-b874-0445c86b69e6"

  # `AcrPull` built-in role definition GUID — used in the ABAC condition on
  # `module.env_github.role_assignments.acr_uaa_bounded`.
  role_acr_pull = "7f951dda-4ed3-4680-a7ca-43fe172d538d"

  env_sub_id = local.environment.subscription_id

  # Runners KV + ACR resource IDs.
  #
  # KV: created by `bootstrap/fleet`; referenced here by synthesized ARM id
  # using the same naming derivation as docs/naming.md.
  #
  # ACR: created by THIS stage on env=mgmt runs (REFACTOR.md Step 1; see
  # main.acr.tf). On env=mgmt resolve to the live resource id so the
  # `acr_uaa_bounded` role assignment in main.github.tf depends on its
  # creation; on non-mgmt envs synthesize the same id (the ACR is created
  # by a prior env=mgmt run and its name derivation is fleet-wide).
  runners_kv_id = join("/", [
    "/subscriptions", local.derived.acr_subscription_id,
    "resourceGroups", local.derived.runners_kv_resource_group,
    "providers/Microsoft.KeyVault/vaults", local.derived.runners_kv_name,
  ])
  fleet_acr_id = var.env == "mgmt" ? azapi_resource.fleet_acr[0].id : join("/", [
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
# Contributor + User Access Administrator at subscription scope to run
# team-bootstrap / env-bootstrap against this env. No Graph permissions
# are required: under PLAN §1 hub-and-spoke, per-env UAMIs do not
# mutate AAD apps (only `uami-fleet-stage0` and `uami-fleet-mgmt` do).

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
      roleDefinitionId = "/subscriptions/${local.env_sub_id}/providers/Microsoft.Authorization/roleDefinitions/${local.role_rbac_admin}"
      principalId      = var.fleet_meta_principal_id
      principalType    = "ServicePrincipal"
    }
  }
}

# --- uami-fleet-mgmt → Key Vault Secrets User on the runners KV (mgmt-only) -
#
# The mgmt cluster's tf-apply.yaml run authenticates as `uami-fleet-mgmt`
# (the env-scope UAMI created by `module.env_github` below). On the
# `matrix.cluster.role == 'management'` leg, the workflow runs an
# `az keyvault secret show` against the runners KV to fetch the
# `fleet-meta` GitHub App PEM, mints an installation token, and uses it
# to publish `MGMT_*` repo variables (Stage 1 mgmt outputs → repo vars
# consumed by spoke clusters' Stage 1/2 plans).
#
# The runners KV uses RBAC authorization (`enableRbacAuthorization=true`
# in `bootstrap/fleet/main.kv.tf`), so subscription-scope Contributor
# does **not** transitively grant data-plane secret read access; an
# explicit `Key Vault Secrets User` assignment scoped to the KV is
# required. Co-located here (rather than in `bootstrap/fleet`) because
# `uami-fleet-mgmt` itself is created in this stage — keeping the
# grant in the same apply graph avoids a cross-stage data dependency.
#
# Gated on `var.env == "mgmt"` because only the mgmt env's UAMI runs
# the publish step; non-mgmt envs' tf-apply.yaml legs never read from
# the runners KV.

resource "azapi_resource" "ra_env_uami_runners_kv_secrets_user" {
  count = var.env == "mgmt" ? 1 : 0

  type      = "Microsoft.Authorization/roleAssignments@2022-04-01"
  name      = uuidv5("url", "fleet-mgmt-runners-kv-secrets-user-${local.runners_kv_id}")
  parent_id = local.runners_kv_id

  body = {
    properties = {
      roleDefinitionId = "/subscriptions/${local.derived.acr_subscription_id}/providers/Microsoft.Authorization/roleDefinitions/${local.role_kv_secrets_user}"
      principalId      = module.env_github.identity.principal_id
      principalType    = "ServicePrincipal"
    }
  }
}
