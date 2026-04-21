# main.runner.tf
#
# Stage -1 self-hosted GitHub Actions runner pool. Single shared repo-scoped
# pool; the trust boundary for downstream workflows is the GitHub Environment
# + federated credential, not network reachability.
#
# Callsite responsibilities (kept outside the vendored module so the
# resulting UAMI id is known at plan time and the module's secret wiring
# can reference it):
#
#   1. Create the runner UAMI (`uami-fleet-runners`) in `rg-fleet-shared`.
#   2. Invoke the vendored ACA+KEDA runner module with:
#        - bring-your-own VNet (networking.*)
#        - no NAT / no public IP (UDR + hub firewall own egress)
#        - per-pool private ACR (module default)
#        - KV-reference for the GitHub App PEM (vendor extension — see
#          terraform/modules/cicd-runners/VENDORING.md §4)
#
# The fleet KV and the `Key Vault Secrets User` role assignment that
# binds this UAMI to it are both owned by this stage (see main.kv.tf).
# ACA's KV reference resolution happens at runtime via the attached UAMI,
# not at PUT time, but we still sequence the runner module after the
# role assignment so the first job execution finds a working grant.
#
# The PEM itself is seeded into the KV under the secret name
# `local.github_app_fleet_runners.private_key_kv_secret` (default
# `fleet-runners-app-pem`) by the `init-gh-apps.sh` helper (PLAN §16.4),
# which runs after bootstrap/fleet completes. bootstrap/fleet itself
# never touches the PEM.

locals {
  runner_uami_name      = "uami-fleet-runners"
  runner_resource_group = "rg-fleet-runners"
  runner_postfix        = "fleet-runners"
  runner_pool_name      = "fleet-runners"

  # The runner pool is co-located with the fleet shared RG
  # (`acr_location`). Pick the matching mgmt region for subnet
  # resolution; fall back to the first mgmt region. The precondition on
  # the `module "runner"` call surfaces a mismatch early.
  runner_mgmt_region = contains(keys(local.mgmt_vnet_ids), local.derived.acr_location) ? (
    local.derived.acr_location
  ) : keys(local.mgmt_vnet_ids)[0]

  # Versionless KV secret URI — points at the fleet KV created in
  # main.kv.tf. The Container App Job resolves the secret at runtime via
  # the attached UAMI; the PEM itself is seeded post-bootstrap by
  # init-gh-apps.sh.
  fleet_runners_app_key_kv_secret_id = "${azapi_resource.fleet_kv.output.properties.vaultUri}secrets/${local.github_app_fleet_runners.private_key_kv_secret}"
}

# --- Runner UAMI -------------------------------------------------------------

resource "azapi_resource" "runner_uami" {
  type      = "Microsoft.ManagedIdentity/userAssignedIdentities@2023-01-31"
  name      = local.runner_uami_name
  parent_id = azapi_resource.rg_fleet_shared.id
  location  = local.derived.acr_location

  body = {}

  response_export_values = ["id", "properties.clientId", "properties.principalId"]
}

# --- Pre-apply validation ----------------------------------------------------
#
# The vendored module's own input validation fires late (inside child
# submodules). We want a single, early, _fleet.yaml-anchored error
# message when the GH App identifiers are missing. Networking inputs
# (mgmt VNet address_space, hub id, central PDZs) are pre-checked by
# `terraform_data.network_preconditions` in main.network.tf.

resource "terraform_data" "runner_preconditions" {
  input = {
    app_id          = local.github_app_fleet_runners.app_id
    installation_id = local.github_app_fleet_runners.installation_id
  }

  lifecycle {
    precondition {
      # GitHub App IDs are numeric strings from GitHub, not ARM ids. Coerce
      # to string before checking so unquoted YAML numeric scalars work too
      # (adopters editing _fleet.yaml by hand may drop the quotes). Reject
      # null/empty/whitespace and the legacy `<...>` sentinel.
      condition     = local.github_app_fleet_runners.app_id != null && trimspace(tostring(local.github_app_fleet_runners.app_id)) != "" && !startswith(tostring(local.github_app_fleet_runners.app_id), "<") && local.github_app_fleet_runners.installation_id != null && trimspace(tostring(local.github_app_fleet_runners.installation_id)) != "" && !startswith(tostring(local.github_app_fleet_runners.installation_id), "<")
      error_message = "clusters/_fleet.yaml: github_app.fleet_runners.{app_id, installation_id} are unset or still `<...>` placeholders. Run ./init-gh-apps.sh to create the three GitHub Apps and let it patch these values in for you. See docs/adoption.md §4 + §5.2."
    }
  }
}

# --- Runner pool (vendored AVM module with local extensions) -----------------

module "runner" {
  source = "../../modules/cicd-runners"
  depends_on = [
    terraform_data.runner_preconditions,
    azapi_resource.ra_runner_kv_secrets_user,
    azapi_resource.fleet_kv_pe_dns_zone_group,
  ]

  postfix  = local.runner_postfix
  location = local.derived.acr_location

  resource_group_creation_enabled = true
  resource_group_name             = local.runner_resource_group

  # GitHub + GitHub App authentication ---------------------------------------
  version_control_system_type                               = "github"
  version_control_system_authentication_method              = "github_app"
  version_control_system_runner_scope                       = "repo"
  version_control_system_organization                       = local.fleet.github_org
  version_control_system_repository                         = local.fleet.github_repo
  version_control_system_pool_name                          = local.runner_pool_name
  version_control_system_github_application_id              = local.github_app_fleet_runners.app_id
  version_control_system_github_application_installation_id = local.github_app_fleet_runners.installation_id

  # Vendor extension: Key Vault reference for the PEM (see VENDORING.md §4).
  # The UAMI attached to the jobs resolves the secret at runtime; the PEM
  # itself never enters Terraform state.
  github_app_key_kv_secret_id = local.fleet_runners_app_key_kv_secret_id
  github_app_key_identity_id  = azapi_resource.runner_uami.output.id

  # Reuse the callsite-created UAMI instead of letting the module create one,
  # so the id is known at plan time and usable in the KV role assignment above.
  user_assigned_managed_identity_creation_enabled = false
  user_assigned_managed_identity_id               = azapi_resource.runner_uami.output.id
  user_assigned_managed_identity_client_id        = azapi_resource.runner_uami.output.properties.clientId
  user_assigned_managed_identity_principal_id     = azapi_resource.runner_uami.output.properties.principalId

  # Networking --------------------------------------------------------------
  #
  # All three subnet / zone references land in repo-owned infrastructure
  # authored by main.network.tf (PLAN §3.4):
  #   - container_app_subnet_id                    → snet-runners in the
  #                                                   co-located mgmt VNet
  #   - container_registry_private_endpoint_subnet → snet-pe-fleet in the
  #                                                   co-located mgmt VNet
  #   - container_registry_dns_zone_id             → adopter-BYO
  #                                                   privatelink.azurecr.io
  #                                                   from networking.private_dns_zones.azurecr
  use_private_networking                               = true
  virtual_network_creation_enabled                     = false
  container_app_subnet_id                              = local.mgmt_snet_runners_ids[local.runner_mgmt_region]
  container_registry_private_endpoint_subnet_id        = local.mgmt_snet_pe_fleet_ids[local.runner_mgmt_region]
  container_registry_private_dns_zone_creation_enabled = false
  container_registry_dns_zone_id                       = local.networking_central.pdz_azurecr

  # Hub firewall handles egress via UDR on the runner subnet; no NAT or
  # public IP owned by this module.
  nat_gateway_creation_enabled = false
  public_ip_creation_enabled   = false

  # Per-pool private ACR + observability ------------------------------------
  container_registry_creation_enabled      = true
  log_analytics_workspace_creation_enabled = true

  tags = {
    fleet     = local.fleet.name
    component = "ci-runners"
    stage     = "bootstrap-fleet"
  }
}

output "runner_uami_id" {
  description = "Resource id of the fleet runner UAMI (uami-fleet-runners)."
  value       = azapi_resource.runner_uami.output.id
}

output "runner_uami_principal_id" {
  description = "Principal id of the fleet runner UAMI."
  value       = azapi_resource.runner_uami.output.properties.principalId
}
