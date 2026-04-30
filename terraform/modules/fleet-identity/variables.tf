# Single input: the parsed `_fleet.yaml` document. Callers do the
# `yamldecode(file(...))` so this module stays testable without having
# to locate a fixture on disk.

variable "fleet_doc" {
  description = <<-EOT
    Parsed `clusters/_fleet.yaml` document. Expected shape (fields this
    module actually reads; PLAN §3.1):

      fleet.name               (string, required)
      fleet.tenant_id          (string, passthrough)
      acr.name_override        (string, optional)
      acr.resource_group       (string, required)
      acr.subscription_id      (string, required)
      acr.location             (string, required)
      runners_keyvault.name_override   (string, optional)
      runners_keyvault.resource_group  (string, optional; defaults to "rg-fleet-runners")
      runners_keyvault.location        (string, optional; defaults to envs.mgmt.location)
      state.storage_account_name_override (string, optional)
      state.resource_group     (string, required)
      state.subscription_id    (string, required)
      state.containers.fleet   (string, required)
      envs.<env>.subscription_id (string, per-env)
      envs.mgmt.location       (string; the canonical location for fleet-wide
                               resources not bound to a cluster env-region)
      networking.private_dns_zones.{blob,vaultcore,azurecr,grafana} (optional)
      networking.envs.<env>.regions.<region>.address_space (list<string>)
      networking.envs.<env>.regions.<region>.location (string, optional)
      networking.envs.<env>.regions.<region>.hub_network_resource_id (string, nullable; BYO hub VNet id, null = opt out of hub peering)
      networking.envs.<env>.regions.<region>.create_reverse_peering (bool, default true)
      networking.envs.<env>.regions.<region>.egress_next_hop_ip (string, nullable)
      github_app.fleet_runners.{app_id,installation_id,private_key_kv_secret} (optional)
  EOT
  type        = any

  # Reject unknown keys at the per-region level. Catches the common
  # nesting mistake where adopters write `use_remote_gateways: true`
  # at the region top level instead of under `hub_peering:` (silent
  # fallback to false otherwise — see the historical F19 finding).
  # The set below mirrors the keys this module's `main.tf` reads via
  # `try(region_block.<key>, ...)`. New per-region fields must be
  # added here at the same time as the read site.
  validation {
    condition = alltrue(flatten([
      for env_name, env_block in try(var.fleet_doc.networking.envs, {}) : [
        for region_name, region_block in try(env_block.regions, {}) : [
          for k in try(keys(region_block), []) :
          contains([
            "address_space",
            "location",
            "hub_network_resource_id",
            "egress_next_hop_ip",
            "create_reverse_peering",
            "hub_peering",
            "dns_servers",
            "subnet_route_table_ids",
          ], k)
        ]
      ]
    ]))
    error_message = "clusters/_fleet.yaml: networking.envs.<env>.regions.<region> contains an unknown key. Allowed: address_space, location, hub_network_resource_id, egress_next_hop_ip, create_reverse_peering, hub_peering, dns_servers, subnet_route_table_ids. Common mistake: writing `use_remote_gateways: true` at the region top level instead of under `hub_peering: { use_remote_gateways: true }`."
  }
}
