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
