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
  value = var.fleet.state.subscription_id
}

output "fleet_shared_resource_group_id" {
  value = azapi_resource.rg_fleet_shared.id
}

output "fleet_stage0_uami" {
  value = {
    resource_id  = azapi_resource.uami_fleet_stage0.id
    client_id    = azapi_resource.uami_fleet_stage0.output.properties.clientId
    principal_id = azapi_resource.uami_fleet_stage0.output.properties.principalId
  }
}

output "fleet_meta_uami" {
  value = {
    resource_id  = azapi_resource.uami_fleet_meta.id
    client_id    = azapi_resource.uami_fleet_meta.output.properties.clientId
    principal_id = azapi_resource.uami_fleet_meta.output.properties.principalId
  }
}

output "fleet_repo_full_name" {
  value = github_repository.fleet.full_name
}

output "team_template_repo_full_name" {
  value = github_repository.team_template.full_name
}
