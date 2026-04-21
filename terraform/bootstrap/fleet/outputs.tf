output "state_storage_account" {
  description = "Name of the fleet-wide TF state storage account. Used in all downstream backend configs."
  value       = azapi_resource.state_sa.name
}

output "state_resource_group" {
  value = azapi_resource.state_rg.name
}

output "state_container_fleet" {
  value = azapi_resource.state_container_fleet.name
}

output "state_subscription_id" {
  value = local.derived.state_subscription
}

output "fleet_shared_resource_group_id" {
  value = azapi_resource.rg_fleet_shared.id
}

output "fleet_stage0_uami" {
  value = {
    resource_id  = module.fleet_repo.environments["stage0"].identity.id
    client_id    = module.fleet_repo.environments["stage0"].identity.client_id
    principal_id = module.fleet_repo.environments["stage0"].identity.principal_id
  }
}

output "fleet_meta_uami" {
  value = {
    resource_id  = module.fleet_repo.environments["meta"].identity.id
    client_id    = module.fleet_repo.environments["meta"].identity.client_id
    principal_id = module.fleet_repo.environments["meta"].identity.principal_id
  }
}

output "fleet_repo_full_name" {
  value = module.fleet_repo.full_name
}

output "mgmt_vnet_resource_ids" {
  description = "Per-region mgmt VNet resource ids, keyed by region (e.g. { eastus = \"/subscriptions/.../virtualNetworks/vnet-<fleet>-mgmt-eastus\" }). Consumed by bootstrap/environment (env=mgmt branch carves cluster-workload subnets as azapi children; non-mgmt envs resolve reverse-peering target via same-region-else-first over the mgmt regions this map lists) and stages/1-cluster (cluster DNS zone VNet link in the cluster's region). Published on the fleet-meta GH environment as MGMT_VNET_RESOURCE_IDS (jsonencoded)."
  value       = local.mgmt_vnet_ids
}

output "mgmt_snet_pe_fleet_ids" {
  description = "Per-region mgmt VNet snet-pe-fleet subnet resource ids (tfstate SA / fleet KV / fleet ACR PE landing subnets), keyed by region. Published as MGMT_PE_FLEET_SUBNET_IDS (jsonencoded)."
  value       = local.mgmt_snet_pe_fleet_ids
}

output "mgmt_snet_runners_ids" {
  description = "Per-region mgmt VNet snet-runners subnet resource ids (ACA-delegated self-hosted GitHub Actions runner pool subnets), keyed by region. Published as MGMT_RUNNERS_SUBNET_IDS (jsonencoded)."
  value       = local.mgmt_snet_runners_ids
}

output "team_template_repo_full_name" {
  value = module.team_template_repo.full_name
}

output "derived_names" {
  description = "Computed resource names; kept as an output for downstream stages and CI diffs against config-loader/load.sh."
  value = {
    state_storage_account = local.derived.state_storage_account
    acr_name              = local.derived.acr_name
    fleet_kv_name         = local.derived.fleet_kv_name
  }
}
