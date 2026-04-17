# main.github.tf
#
# Per-env GitHub environment and variables. Reviewer count is parameter-
# driven; see variables.tf (0 for nonprod/mgmt, 1 for mgmt if you decide
# to gate it, 2 for prod).

resource "github_repository_environment" "env" {
  repository  = local.fleet.github_repo
  environment = "fleet-${var.env}"

  dynamic "reviewers" {
    for_each = var.env_reviewers_count > 0 ? [1] : []
    content {
      teams = []
      users = []
    }
  }

  deployment_branch_policy {
    protected_branches     = true
    custom_branch_policies = false
  }
}

locals {
  env_vars = {
    AZURE_CLIENT_ID         = azapi_resource.uami_env.output.properties.clientId
    AZURE_TENANT_ID         = local.fleet.tenant_id
    AZURE_SUBSCRIPTION_ID   = local.env_sub_id
    TFSTATE_CONTAINER       = local.state_container_name
    TFSTATE_STORAGE_ACCOUNT = local.derived.state_storage_account
    TFSTATE_RESOURCE_GROUP  = local.derived.state_resource_group
    FLEET_NAME              = local.fleet.name

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
  }
}

resource "github_actions_environment_variable" "env_vars" {
  for_each      = local.env_vars
  repository    = local.fleet.github_repo
  environment   = github_repository_environment.env.environment
  variable_name = each.key
  value         = each.value
}
