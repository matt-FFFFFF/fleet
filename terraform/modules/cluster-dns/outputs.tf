# modules/cluster-dns/outputs.tf

output "zone_fqdn" {
  description = "Private DNS zone FQDN (== var.zone_fqdn); exposed for symmetry with PLAN §3.4 consumers."
  value       = var.zone_fqdn
}

output "zone_resource_id" {
  description = "Private DNS zone ARM id. Scope for `Private DNS Zone Contributor` role assignment (external-dns UAMI) authored once that UAMI lands (STATUS §4 Stage 1 TODO)."
  value       = azapi_resource.zone.output.id
}

output "vnet_link_resource_ids" {
  description = "Map of logical key → `virtualNetworkLinks` resource id (one entry per link)."
  value       = { for k, r in azapi_resource.vnet_link : k => r.output.id }
}
