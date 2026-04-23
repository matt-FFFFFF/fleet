# main.github.tf
#
# Per-env GitHub environment + UAMI + FIC + env-scoped Azure role
# assignments, delivered via the vendored github-repo/modules/environment
# submodule. Calls the submodule directly — the fleet repo itself is
# already owned by bootstrap/fleet, so there is no need to go through the
# root `github-repo` module here.
#
# Reviewer count is parameter-driven (see variables.tf): 0 for nonprod /
# mgmt, 2 for prod. A non-null reviewers block is the mechanism that
# enables the GitHub "required reviewers" gate.

locals {
  env_name = "fleet-${var.env}"
}

# -----------------------------------------------------------------------------
# GitHub Actions deployment environment + its UAMI/FIC/RBAC.
#
# The submodule's `repository_full_name` / `actions_oidc_subject_claims` /
# `oidc_subject_claim_values` inputs are what the root module would normally
# pass through from its OIDC claim machinery. Here we pass them explicitly
# (see bootstrap/fleet/main.github.tf for the matching config on the fleet
# repo itself).
# -----------------------------------------------------------------------------

# Matches bootstrap/fleet's `actions_oidc_subject_claims` configuration.
# Keep in sync — both sides must agree on the claim format, or the FIC
# subject this module builds will not validate against the actual
# GitHub-emitted token.
locals {
  oidc_claim_keys = ["repository_owner_id", "repository_id", "environment"]

  # Owner + repo IDs are looked up via data sources (the repo is owned by
  # bootstrap/fleet, so we cannot reference the resource directly from here).
  oidc_subject_claim_values = {
    repository_owner_id = tostring(data.github_organization.fleet.id)
    repository_id       = tostring(data.github_repository.fleet.repo_id)
  }
}

data "github_organization" "fleet" {
  name = local.fleet.github_org
}

data "github_repository" "fleet" {
  full_name = "${local.fleet.github_org}/${local.fleet.github_repo}"
}

module "env_github" {
  source = "../../modules/github-repo/modules/environment"

  repository        = local.fleet.github_repo
  environment       = local.env_name
  reviewers         = var.env_reviewers_count > 0 ? { teams = [], users = [] } : null
  deployment_policy = { protected_branches = true, custom_branch_policies = false }
  # `variables` intentionally left at default `{}` here; env variables that
  # reference the submodule's own UAMI client_id are set by the callsite
  # `github_actions_environment_variable.env_vars` resource below, to break
  # the otherwise-inevitable self-referential cycle.

  repository_full_name = "${local.fleet.github_org}/${local.fleet.github_repo}"
  actions_oidc_subject_claims = {
    use_default        = false
    include_claim_keys = local.oidc_claim_keys
  }
  oidc_subject_claim_values = local.oidc_subject_claim_values

  identity = {
    name      = "uami-fleet-${var.env}"
    parent_id = azapi_resource.rg_env_shared.id
    location  = local.location
    # Preserve the legacy FIC name so the refactor does not cause a rename.
    fic_name = "gh-fleet-${var.env}"
  }

  role_assignments = {
    sub_contrib = {
      role_definition_id = "/subscriptions/${local.env_sub_id}/providers/Microsoft.Authorization/roleDefinitions/${local.role_contributor}"
      scope              = "/subscriptions/${local.env_sub_id}"
    }
    blob_contrib = {
      role_definition_id = "/subscriptions/${local.derived.state_subscription}/providers/Microsoft.Authorization/roleDefinitions/${local.role_blob_data_ctrb}"
      scope              = azapi_resource.state_container_env.id
    }
    fleet_kv_secrets_user = {
      role_definition_id = "/subscriptions/${local.derived.acr_subscription_id}/providers/Microsoft.Authorization/roleDefinitions/${local.role_kv_secrets_user}"
      scope              = local.fleet_kv_id
    }
    acr_uaa_bounded = {
      role_definition_id = "/subscriptions/${local.derived.acr_subscription_id}/providers/Microsoft.Authorization/roleDefinitions/${local.role_rbac_admin}"
      scope              = local.fleet_acr_id
      condition_version  = "2.0"
      condition          = <<-COND
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

# -----------------------------------------------------------------------------
# Environment variables for the fleet-<env> GH Actions environment.
#
# Declared outside `module.env_github` to break the cycle that would form
# from feeding the submodule's own `identity.client_id` output back into
# its `variables` input.
# -----------------------------------------------------------------------------

locals {
  env_vars = merge(
    {
      AZURE_CLIENT_ID       = module.env_github.identity.client_id
      AZURE_TENANT_ID       = local.fleet.tenant_id
      AZURE_SUBSCRIPTION_ID = local.env_sub_id

      # Fleet-env UAMI principalId — consumed by Stage 1 as the
      # `Azure Kubernetes Service RBAC Cluster Admin` assignee so this
      # same identity (which Stage 2 then runs as) can apply
      # kubernetes_*/helm_release resources against a
      # local-accounts-disabled cluster. Exposing principalId (not just
      # clientId) avoids a Stage-1 `azuread_service_principal` data
      # source lookup.
      FLEET_ENV_UAMI_PRINCIPAL_ID = module.env_github.identity.principal_id
      TFSTATE_CONTAINER           = local.state_container_name
      TFSTATE_STORAGE_ACCOUNT     = local.derived.state_storage_account
      TFSTATE_RESOURCE_GROUP      = local.derived.state_resource_group
      FLEET_NAME                  = local.fleet.name

      # Env observability IDs — informational only; Stage 1 looks these up by
      # derived name at plan time (see PLAN §4.1 / Stage 1 azapi data sources).
      MONITOR_WORKSPACE_ID           = azapi_resource.amw.id
      DCE_ID                         = azapi_resource.dce.id
      DCE_LOGS_INGESTION_ENDPOINT    = azapi_resource.dce.output.properties.logsIngestion.endpoint
      DCE_METRICS_INGESTION_ENDPOINT = azapi_resource.dce.output.properties.metricsIngestion.endpoint
      GRAFANA_ID                     = azapi_resource.amg.id
      GRAFANA_ENDPOINT               = azapi_resource.amg.output.properties.endpoint
      ACTION_GROUP_ID                = azapi_resource.ag.id
      NSP_ID                         = azapi_resource.nsp.id
    },
    # PLAN §3.4 / Phase D — per-region networking ids. Stage 1 picks
    # `<ENV>_<REGION>_VNET_RESOURCE_ID` / `<ENV>_<REGION>_NODE_ASG_RESOURCE_ID`
    # / `<ENV>_<REGION>_ROUTE_TABLE_RESOURCE_ID` off the env (selected
    # by `cluster.env`) and routes them into
    # TF_VAR_env_region_vnet_resource_id / TF_VAR_node_asg_resource_id
    # / TF_VAR_route_table_resource_id for each cluster leg of
    # tf-apply.yaml.
    {
      for r, vid in local.env_vnet_id_by_region :
      "${upper(var.env)}_${upper(r)}_VNET_RESOURCE_ID" => vid
    },
    {
      for r, asg in azapi_resource.node_asg :
      "${upper(var.env)}_${upper(r)}_NODE_ASG_RESOURCE_ID" => asg.id
    },
    {
      for r, rt in azapi_resource.route_table :
      "${upper(var.env)}_${upper(r)}_ROUTE_TABLE_RESOURCE_ID" => rt.id
    },
    {
      for r, sid in local.env_snet_pe_env_id_by_region :
      "${upper(var.env)}_${upper(r)}_PE_SUBNET_ID" => sid
    },
  )
}

resource "github_actions_environment_variable" "env_vars" {
  for_each      = local.env_vars
  repository    = local.fleet.github_repo
  environment   = module.env_github.environment.environment
  variable_name = each.key
  value         = each.value
}

# -----------------------------------------------------------------------------
# Microsoft Graph app-role assignment — `Application.ReadWrite.OwnedBy` on
# the per-env UAMI. Lets Stage 1 (mgmt cluster; Kargo password rotation) and
# Stage 2 (every cluster; Argo per-cluster FIC writes + Kargo FIC on mgmt)
# perform owner-scoped CRUD on the Argo + Kargo AAD apps, provided the env
# UAMI is listed in each app's `owners` attribute (see
# `terraform/stages/0-fleet/main.aad.tf`). Replaces the tenant-wide
# `Application Administrator` directory role previously held by
# `fleet-stage0` (STATUS item 14).
#
# The caller (`uami-fleet-meta`) needs `AppRoleAssignment.ReadWrite.All` on
# Graph to create this resource; that grant is authored by `bootstrap/fleet`
# (main.identities.tf `meta_approle_rw_all`) and must apply before this
# stage runs.
# -----------------------------------------------------------------------------

data "azuread_service_principal" "msgraph" {
  client_id = "00000003-0000-0000-c000-000000000000"
}

resource "azuread_app_role_assignment" "env_app_rw_owned_by" {
  app_role_id         = "18a4783c-866b-4cc7-a460-3d5e5662c884" # Application.ReadWrite.OwnedBy
  principal_object_id = module.env_github.identity.principal_id
  resource_object_id  = data.azuread_service_principal.msgraph.object_id
}
