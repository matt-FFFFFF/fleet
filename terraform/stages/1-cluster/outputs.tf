# stages/1-cluster/outputs.tf
#
# Full Stage 1 output surface per PLAN §4 Stage 1 lines 1922-1939.
# All values are consumed by Stage 2 (running in the same CI job) as
# tfvars via the `tf-apply.yaml` workflow — no remote state reads.
#
# Passthroughs from Stage 0 / bootstrap/environment (fleet KV, env AMW,
# env DCE, env AG) save Stage 2 from redoing the lookup.

# --- AKS -------------------------------------------------------------------

output "aks_host" {
  description = "AKS apiserver URL — Stage 2 Kubernetes/Helm provider host."
  value       = try(module.aks.host, null)
  sensitive   = false
}

output "aks_cluster_ca_certificate" {
  description = "Base64-encoded cluster CA — Stage 2 Kubernetes/Helm provider cluster_ca_certificate."
  value       = try(module.aks.cluster_ca_certificate, null)
  sensitive   = true
}

output "aks_oidc_issuer_url" {
  description = "OIDC issuer URL — consumed by Stage 2 FIC creation (external-dns, ESO, team UAMIs) and the mgmt cluster's Kargo FIC."
  value       = try(module.aks.oidc_issuer_url, null)
}

output "aks_cluster_resource_id" {
  description = "Full AKS ARM id — used by Stage 2 for cross-cluster references (Kargo manifests, dashboards)."
  value       = try(module.aks.resource_id, null)
}

# --- UAMI outputs (consumed by Stage 2 for FIC creation + SA annotations) --

output "external_dns_identity_client_id" {
  description = "external-dns UAMI clientId. Stage 2 annotates the external-dns SA with this value + creates the FIC."
  value       = azapi_resource.uami_external_dns.output.properties.clientId
}

output "external_dns_identity_resource_id" {
  description = "external-dns UAMI ARM id. FIC parent ref."
  value       = azapi_resource.uami_external_dns.id
}

output "eso_identity_client_id" {
  description = "ESO UAMI clientId. Stage 2 annotates the external-secrets SA with this value + creates the FIC."
  value       = azapi_resource.uami_eso.output.properties.clientId
}

output "eso_identity_resource_id" {
  description = "ESO UAMI ARM id. FIC parent ref."
  value       = azapi_resource.uami_eso.id
}

output "team_identities" {
  description = "Map of team → { client_id, resource_id }. One entry per team opted into this cluster (cluster.yaml `teams:` list). Stage 2 creates a FIC per team on each UAMI."
  value = {
    for t, u in azapi_resource.uami_team :
    t => {
      client_id   = u.output.properties.clientId
      resource_id = u.id
    }
  }
}

# --- Key Vault outputs -----------------------------------------------------

output "cluster_keyvault_id" {
  description = "Cluster Key Vault ARM id. Scope for ESO's KV Secrets User assignment (authored here) and the CSI driver config in Stage 2."
  value       = module.cluster_kv.resource_id
}

output "cluster_keyvault_name" {
  description = "Cluster Key Vault name."
  value       = module.cluster_kv.name
}

output "cluster_keyvault_uri" {
  description = "Cluster Key Vault data-plane URI (`https://<name>.vault.azure.net/`). Stage 2 ClusterSecretStore + CSI driver config."
  value       = module.cluster_kv.vault_uri
}

output "fleet_keyvault_id" {
  description = "Fleet Key Vault ARM id — passthrough from `var.fleet_keyvault_id` (published by Stage 0) so Stage 2 doesn't reach back to Stage 0 state."
  value       = var.fleet_keyvault_id
}

# --- DNS outputs (consumed by platform-gitops ApplicationSet params) --------

output "dns_zone_fqdn" {
  description = "Cluster private DNS zone FQDN (`<cluster>.<region>.<env>.<fleet_root>`). External-dns --domain-filter."
  value       = module.cluster_dns.zone_fqdn
}

output "dns_zone_resource_id" {
  description = "Cluster private DNS zone resource id. Also the scope of the external-dns UAMI's Private DNS Zone Contributor assignment (authored here)."
  value       = module.cluster_dns.zone_resource_id
}

output "ingress_domain" {
  description = "Alias of dns_zone_fqdn (ingress hostnames == `*.<dns_zone_fqdn>`)."
  value       = module.cluster_dns.zone_fqdn
}

# --- Observability outputs -------------------------------------------------

output "prometheus_dcr_id" {
  description = "Per-cluster Prometheus DCR ARM id (`dcr-prom-<cluster>`). Null when managed-prometheus is disabled for this cluster."
  value       = length(module.cluster_monitoring) > 0 ? module.cluster_monitoring[0].dcr_id : null
}

output "env_monitor_workspace_id" {
  description = "Env Azure Monitor Workspace ARM id — passthrough so Stage 2 / ApplicationSet params can reference it without re-lookup."
  value       = var.env_monitor_workspace_id
}

output "env_dce_id" {
  description = "Env Data Collection Endpoint ARM id — passthrough."
  value       = var.env_dce_id
}

output "env_action_group_id" {
  description = "Env Action Group ARM id — passthrough (consumed by Stage 2 / alert wiring)."
  value       = var.env_action_group_id
}

# --- Networking outputs ----------------------------------------------------

output "api_subnet_id" {
  description = "Per-cluster /28 api subnet (delegated to Microsoft.ContainerService/managedClusters)."
  value       = azapi_resource.snet_aks_api.output.id
}

output "node_subnet_id" {
  description = "Per-cluster /25 nodes subnet (vnet_subnet_id for every agent pool in this cluster)."
  value       = azapi_resource.snet_aks_nodes.output.id
}

# --- Passthrough outputs ----------------------------------------------------

output "tenant_id" {
  description = "AAD tenant id — convenience passthrough for Stage 2 provider auth."
  value       = local.fleet.tenant_id
}

output "subscription_id" {
  description = "Cluster subscription id — convenience passthrough for Stage 2 provider auth."
  value       = local.cluster.subscription_id
}
