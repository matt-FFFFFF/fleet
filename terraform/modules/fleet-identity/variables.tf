# Single input: the parsed `_fleet.yaml` document. Callers do the
# `yamldecode(file(...))` so this module stays testable without having
# to locate a fixture on disk.

variable "fleet_doc" {
  description = <<-EOT
    Parsed `clusters/_fleet.yaml` document. Expected shape (fields this
    module actually reads):

      fleet.name               (string, required)
      fleet.primary_region     (string, required)
      fleet.tenant_id          (string, passthrough)
      acr.name_override        (string, optional)
      acr.resource_group       (string, required)
      acr.subscription_id      (string, required)
      acr.location             (string, required)
      keyvault.name_override   (string, optional)
      keyvault.resource_group  (string, optional; defaults to acr.resource_group)
      keyvault.location        (string, optional; defaults to fleet.primary_region)
      state.storage_account_name_override (string, optional)
      state.resource_group     (string, required)
      state.subscription_id    (string, required)
      state.containers.fleet   (string, required)
      networking.*             (optional; all fields try-guarded)
      github_app.fleet_runners.{app_id,installation_id,private_key_kv_secret} (optional)
  EOT
  type        = any
}
