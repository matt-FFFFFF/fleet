# modules/cluster-monitoring/outputs.tf

output "dcr_id" {
  description = "Data Collection Rule ARM id (`dcr-prom-<cluster>`)."
  value       = azapi_resource.dcr_prom.id
}

output "dcra_id" {
  description = "DCR association ARM id (binds the DCR to the AKS cluster)."
  value       = azapi_resource.dcra_prom.id
}

output "rule_group_ids" {
  description = "Map of rule-group short key → ARM id for the three authored Prometheus rule groups."
  value = {
    node = azapi_resource.prg_node.id
    k8s  = azapi_resource.prg_k8s.id
    ux   = azapi_resource.prg_ux.id
  }
}
