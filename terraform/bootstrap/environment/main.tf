# bootstrap/environment
#
# Per-env scaffolding (see PLAN §4.1). Invoked by .github/workflows/env-bootstrap.yaml
# under the `fleet-meta` environment (2-reviewer gate), one run per env.
#
# Fleet identity is sourced from clusters/_fleet.yaml; only env-scope inputs
# are supplied as variables.
#
# Resources are split across:
#   main.state.tf         per-env state container
#   main.identities.tf    uami-fleet-<env> + FIC + env-scoped RBAC + meta sub RBAC
#   main.observability.tf NSP + AMW + DCE + Grafana + PE + Action Group
#   main.github.tf        fleet-<env> GH environment + variables

locals {
  fleet_yaml_path = "${path.module}/../../../clusters/_fleet.yaml"
  fleet_doc       = yamldecode(file(local.fleet_yaml_path))

  fleet = local.fleet_doc.fleet
  # Direct lookup — a bad var.env is caught earlier by the precondition on
  # azapi_resource.state_container_env (main.state.tf), which produces an
  # actionable error naming the declared envs.
  environment = local.fleet_doc.environments[var.env]
  observ      = local.fleet_doc.observability
  dns         = local.fleet_doc.dns

  location = var.location != "" ? var.location : local.fleet.primary_region

  derived = {
    state_storage_account = coalesce(
      try(local.fleet_doc.state.storage_account_name_override, ""),
      substr("st${local.fleet.name}tfstate", 0, 24),
    )
    state_resource_group = local.fleet_doc.state.resource_group
    state_subscription   = local.fleet_doc.state.subscription_id

    acr_name = coalesce(
      try(local.fleet_doc.acr.name_override, ""),
      "acr${local.fleet.name}shared",
    )
    acr_resource_group  = local.fleet_doc.acr.resource_group
    acr_subscription_id = local.fleet_doc.acr.subscription_id

    fleet_kv_name = coalesce(
      try(local.fleet_doc.keyvault.name_override, ""),
      substr("kv-${local.fleet.name}-fleet", 0, 24),
    )
  }
}
