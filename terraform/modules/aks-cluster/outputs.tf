# modules/aks-cluster/outputs.tf

output "resource_id" {
  description = "Full ARM id of the managed cluster. Used as the scope for RBAC role assignments (Stage 1 identity/RBAC phase)."
  value       = module.aks.resource_id
}

output "host" {
  description = "AKS apiserver URL. Stage 2 Kubernetes/Helm provider `host`."
  value       = try(module.aks.admin_kube_config.host, null)
}

output "cluster_ca_certificate" {
  description = "Base64-encoded cluster CA. Stage 2 Kubernetes/Helm provider `cluster_ca_certificate`."
  value       = try(module.aks.admin_kube_config.cluster_ca_certificate, null)
  sensitive   = true
}

output "oidc_issuer_url" {
  description = "AKS OIDC issuer URL. Required by Stage 2 for Federated Identity Credential creation."
  value       = try(module.aks.oidc_issuer_url, null)
}

output "cluster_identity" {
  description = "User-assigned managed identity attached to the cluster (NOT the kubelet identity). Kubelet identity stays AKS-managed for AcrPull role assignments authored in the identity/RBAC phase."
  value = {
    resource_id  = azapi_resource.cluster_uami.output.id
    client_id    = azapi_resource.cluster_uami.output.properties.clientId
    principal_id = azapi_resource.cluster_uami.output.properties.principalId
  }
}
