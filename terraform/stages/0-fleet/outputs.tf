# outputs.tf
#
# Outputs published by tf-apply.yaml as fleet-wide GitHub repository variables
# (via the `stage0-publisher` GitHub App, scope = variables:write). Consumed
# by downstream stages as `vars.<UPPER_SNAKE_NAME>`. All values are
# non-sensitive identity facts; no secret material is ever a Stage 0 output
# (the Argo RP secret goes directly into the fleet KV via azapi).
#
# Variable-name mapping matches PLAN §4 Stage 0 "Outputs" table exactly.

# --- Fleet shared infrastructure ---------------------------------------------

output "acr_login_server" {
  description = "ACR FQDN (<name>.azurecr.io). Consumed by Stage 1/2 and team repo CI."
  value       = azapi_resource.acr.output.properties.loginServer
}

output "acr_resource_id" {
  description = "ACR resource id. Consumed by Stage 1 for AcrPull role assignments on kubelet identities."
  value       = azapi_resource.acr.id
}

output "fleet_keyvault_id" {
  description = "Fleet KV resource id. Consumed by Stage 1 for Key Vault Secrets User role assignments on ESO UAMIs."
  value       = azapi_resource.fleet_kv.id
}

output "fleet_keyvault_name" {
  description = "Fleet KV name. Consumed by Stage 2 for the platform-identity secret and ESO ClusterSecretStore config."
  value       = azapi_resource.fleet_kv.name
}

output "fleet_resource_group_name" {
  description = "Informational — rg-fleet-shared."
  value       = local.derived.acr_resource_group
}

# --- AAD applications --------------------------------------------------------

output "argocd_aad_application_id" {
  description = "Argo AAD app clientId. Consumed by every cluster's Stage 2 (Helm values + platform-identity)."
  value       = azuread_application.argocd.client_id
}

output "argocd_aad_application_object_id" {
  description = "Argo AAD app directory object id. Parent ref for per-cluster Stage 2 FICs."
  value       = azuread_application.argocd.object_id
}

output "kargo_aad_application_id" {
  description = "Kargo AAD app clientId. Consumed by the mgmt cluster's Stage 2 (Kargo Helm values)."
  value       = azuread_application.kargo.client_id
}

output "kargo_aad_application_object_id" {
  description = "Kargo AAD app directory object id. Parent ref for mgmt Stage 1 (azuread_application_password) and Stage 2 (FIC)."
  value       = azuread_application.kargo.object_id
}

# --- Kargo mgmt UAMI (fleet-wide singleton) ---------------------------------

output "kargo_mgmt_uami_resource_id" {
  description = "Kargo UAMI resource id. Parent ref for the Kargo FIC created by the mgmt cluster's Stage 2."
  value       = azapi_resource.uami_kargo_mgmt.id
}

output "kargo_mgmt_uami_principal_id" {
  description = "Kargo UAMI principalId. Consumed by every workload cluster's Stage 1 as the principal for AKS RBAC Reader."
  value       = azapi_resource.uami_kargo_mgmt.output.properties.principalId
}

output "kargo_mgmt_uami_client_id" {
  description = "Kargo UAMI clientId. Consumed by mgmt Stage 2 as the workload-identity client-id annotation on the kargo-controller SA."
  value       = azapi_resource.uami_kargo_mgmt.output.properties.clientId
}

# --- Derived names (kept for CI parity check; see PLAN §16.9.10) ------------

output "derived_names" {
  description = "Computed resource names. Diffed against terraform/config-loader/load.sh output in CI."
  value = {
    acr_name      = local.derived.acr_name
    fleet_kv_name = local.derived.fleet_kv_name
  }
}
