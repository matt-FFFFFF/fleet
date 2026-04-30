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
#        - public networking (see "Networking" below; PLAN §15)
#        - per-pool ACR + LAW (module defaults)
#        - KV-reference for the GitHub App PEM (vendor extension — see
#          terraform/modules/cicd-runners/VENDORING.md §4)
#
# The runners KV and the `Key Vault Secrets User` role assignment that
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
  runner_uami_name = "uami-fleet-runners"
  runner_postfix   = "fleet-runners"
  runner_pool_name = "fleet-runners"

  # Versionless KV secret URI — points at the runners KV created in
  # main.kv.tf. The Container App Job resolves the secret at runtime via
  # the attached UAMI; the PEM itself is seeded post-bootstrap by
  # init-gh-apps.sh.
  fleet_runners_app_key_kv_secret_id = "${azapi_resource.runners_kv.output.properties.vaultUri}secrets/${local.github_app_fleet_runners.private_key_kv_secret}"
}

# --- Runner pool resource group ---------------------------------------------
#
# Owns: the runner pool's vendored module resources AND the runner-pool
# Key Vault (parent_id of azapi_resource.runners_kv in main.kv.tf). The
# RG must be created in this stage rather than by the vendored module
# (`resource_group_creation_enabled = false` below) so the KV's
# parent_id can resolve at plan time. RG name is fleet-wide literal
# `rg-fleet-runners` (PLAN §3) — matches `local.derived.runners_kv_resource_group`
# default; CI parity check enforced.

resource "azapi_resource" "rg_fleet_runners" {
  type      = "Microsoft.Resources/resourceGroups@2024-03-01"
  name      = local.derived.runners_kv_resource_group
  parent_id = "/subscriptions/${local.derived.acr_subscription_id}"
  location  = local.derived.acr_location

  body = {}
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
    azapi_resource.runners_kv_pe_dns_zone_group,
    azapi_data_plane_resource.fleet_runners_pem_secret,
  ]

  postfix  = local.runner_postfix
  location = local.derived.acr_location

  # Container Registry name. Without this override the vendored module
  # would fall back to `acr${var.postfix}` = `acrfleetrunners` — a
  # literal string shared by every adopter using this template, which
  # collides globally on the first apply. Microsoft.ContainerRegistry/
  # registries names are global, ≤ 50 chars, lowercase alnum.
  # docs/naming.md "Runner ACR (per-pool)" row.
  container_registry_name = "acr${local.fleet.name}runners"

  resource_group_creation_enabled = false
  resource_group_name             = azapi_resource.rg_fleet_runners.name

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
  # Private networking is currently DISABLED (see PLAN §15 "Runner-pool LAW + ACR private networking deferred"). The
  # vendored module's LAW defaults flip both
  # `log_analytics_workspace_internet_ingestion_enabled` and
  # `log_analytics_workspace_internet_query_enabled` to the negation of
  # `use_private_networking` and the module does not author any
  # private-link path (AMPLS/NSP) for the workspace, so enabling private
  # networking without first landing AMPLS/NSP results in a LAW that
  # cannot ingest from the runner pool nor be queried from the portal.
  #
  # Until the §15 deferral closes (NSP or AMPLS for the runner LAW + DCE), the
  # callsite ships the runner pool with public networking:
  #   - ACR is created with public network access enabled.
  #   - The Container App Environment runs on the ACA-platform-managed
  #     VNet (no infrastructure subnet).
  #   - LAW ingestion + query traverse the public endpoint.
  #
  # The fleet-plane subnets and central PDZ refs in main.network.tf and
  # `_fleet.yaml.networking` remain authored — they are still consumed by
  # the tfstate SA, runners KV, and fleet ACR PEs. They simply do not
  # land on this module call. When the §15 deferral closes, the
  # `container_app_subnet_id`, `container_registry_private_endpoint_subnet_id`,
  # `container_registry_private_dns_zone_creation_enabled`, and
  # `container_registry_dns_zone_id` inputs return here together with
  # `use_private_networking = true`.
  use_private_networking           = false
  virtual_network_creation_enabled = false

  # Hub firewall handles egress via UDR on the runner subnet; no NAT or
  # public IP owned by this module. (These are also gated on
  # use_private_networking inside the module, so they are inert today,
  # but kept explicit so the intent survives future re-enablement.)
  nat_gateway_creation_enabled = false
  public_ip_creation_enabled   = false

  # Per-pool ACR + observability --------------------------------------------
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
