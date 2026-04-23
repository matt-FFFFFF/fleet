# modules/cluster-kv/outputs.tf

output "resource_id" {
  description = "Key Vault ARM id. Scope for `Key Vault Secrets User` role assignments (ESO UAMI, etc.)."
  value       = azapi_resource.kv.id
}

output "name" {
  description = "Key Vault name (== var.name; exposed for symmetry)."
  value       = var.name
}

output "vault_uri" {
  description = "Key Vault data-plane URI (`https://<name>.vault.azure.net/`). Consumed by Stage 2 for ESO ClusterSecretStore + CSI driver config."
  value       = azapi_resource.kv.output.properties.vaultUri
}
