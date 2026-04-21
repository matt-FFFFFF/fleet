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
      keyvault.name_override   (string, optional)
      keyvault.resource_group  (string, optional; defaults to acr.resource_group)
      keyvault.location        (string, optional; defaults to envs.mgmt.location)
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
}
