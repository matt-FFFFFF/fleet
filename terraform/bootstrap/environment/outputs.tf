output "env_uami" {
  value = {
    resource_id  = module.env_github.identity.id
    client_id    = module.env_github.identity.client_id
    principal_id = module.env_github.identity.principal_id
  }
}

output "env_state_container" {
  value = azapi_resource.state_container_env.name
}

output "env_resource_groups" {
  value = {
    shared = azapi_resource.rg_env_shared.name
    dns    = azapi_resource.rg_env_dns.name
    obs    = azapi_resource.rg_env_obs.name
  }
}

output "observability" {
  value = {
    amw_id     = azapi_resource.amw.id
    dce_id     = azapi_resource.dce.id
    grafana_id = azapi_resource.amg.id
    ag_id      = azapi_resource.ag.id
    nsp_id     = azapi_resource.nsp.id
  }
}

# PLAN §3.4 / Phase D — per-region networking outputs consumed by Stage 1
# via the `<ENV>_<REGION>_VNET_RESOURCE_ID` / `<ENV>_<REGION>_NODE_ASG_RESOURCE_ID`
# repo-environment variables published by main.github.tf.
output "env_region_vnet_resource_ids" {
  description = "Map of region (e.g. \"eastus\") → env VNet resource id authored by this stage."
  value       = local.env_vnet_id_by_region
}

output "env_region_node_asg_resource_ids" {
  description = "Map of region → shared `asg-nodes-<env>-<region>` resource id."
  value       = { for r, a in azapi_resource.node_asg : r => a.id }
}

output "env_region_pe_subnet_ids" {
  description = "Map of region → derived `snet-pe-env` subnet resource id."
  value       = local.env_snet_pe_env_id_by_region
}

output "env_region_route_table_resource_ids" {
  description = "Map of region → `rt-aks-<env>-<region>` route table resource id. Stage 1 sets `routeTableId` on both the per-cluster api and nodes subnets from this (PLAN §3.4 UDR egress)."
  value       = { for r, rt in azapi_resource.route_table : r => rt.id }
}
