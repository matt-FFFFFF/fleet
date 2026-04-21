# stages/1-cluster/outputs.tf
#
# Phase E scope: only the outputs Stage 2 / ApplicationSet parameters
# need for the networking-only slice. The full Stage-1 output surface
# listed in PLAN §4 (KV ids, UAMI client_ids, Prometheus DCR id, etc.)
# lands when their owning resources do. Each output below carries a
# header comment linking back to its consumer so the remaining gaps
# are explicit when Stage 2 starts consuming them.

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
  description = "Full AKS ARM id — scope for the RBAC Cluster Admin / Reader role assignments Stage 1 lands when identity/RBAC phase follows (STATUS §4 Stage 1 TODO)."
  value       = try(module.aks.resource_id, null)
}

# --- Networking outputs -----------------------------------------------------
#
# Surfaced so ApplicationSet parameter generators (platform-gitops) and
# Stage 2 role-assignment calls can reference them without re-deriving.

output "api_subnet_id" {
  description = "Per-cluster /28 api subnet (delegated to Microsoft.ContainerService/managedClusters)."
  value       = azapi_resource.snet_aks_api.output.id
}

output "node_subnet_id" {
  description = "Per-cluster /25 nodes subnet (vnet_subnet_id for every agent pool in this cluster)."
  value       = azapi_resource.snet_aks_nodes.output.id
}

# --- DNS outputs (consumed by platform-gitops ApplicationSet params) --------

output "dns_zone_fqdn" {
  description = "Cluster private DNS zone FQDN (`<cluster>.<region>.<env>.<fleet_root>`). External-dns --domain-filter."
  value       = module.cluster_dns.zone_fqdn
}

output "dns_zone_resource_id" {
  description = "Cluster private DNS zone resource id. Scope for the `Private DNS Zone Contributor` role assignment (external-dns UAMI) — authored once that UAMI lands (STATUS §4 Stage 1 TODO)."
  value       = module.cluster_dns.zone_resource_id
}

output "ingress_domain" {
  description = "Alias of dns_zone_fqdn (ingress hostnames == `*.<dns_zone_fqdn>`)."
  value       = module.cluster_dns.zone_fqdn
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
