output "fleet" {
  description = "Passthrough of `fleet_doc.fleet` (name, tenant_id, etc.)."
  value       = local.fleet
}

output "derived" {
  description = "Derived names per docs/naming.md."
  value       = local.derived
}

output "networking" {
  description = "Try-guarded private-networking identifiers from fleet_doc.networking.*. Values may be null."
  value       = local.networking
}

output "github_app_fleet_runners" {
  description = "fleet-runners GH App coordinates (app_id, installation_id, private_key_kv_secret)."
  value       = local.github_app_fleet_runners
}
