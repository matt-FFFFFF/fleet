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
# The `Key Vault Secrets User` role assignment that binds this UAMI to
# the fleet KV is **owned by Stage 0**, not this stage: the fleet KV
# does not exist yet at Stage -1 (Stage 0 creates it), and ARM rejects
# Microsoft.Authorization/roleAssignments PUT against a non-existent
# scope with a 404. Stage 0 reads the runner UAMI principal id from
# the `runner_uami_principal_id` output below and issues the role
# assignment against the KV it creates.
#
# Stage 0 also seeds the PEM into the fleet KV under the secret name
# `local.github_app_fleet_runners.private_key_kv_secret` (default
# `fleet-runners-app-pem`) and publishes the `fleet-runners` App IDs as
# repo variables. bootstrap/fleet itself never touches the PEM.

locals {
  runner_uami_name      = "uami-fleet-runners"
  runner_resource_group = "rg-fleet-runners"
  runner_postfix        = "fleet-runners"
  runner_pool_name      = "fleet-runners"

  # Versionless KV secret URI — constructed, not read. The fleet KV is
  # created by Stage 0, so no data lookup is possible or needed here; the
  # Container App Job resolves the secret at runtime via the attached UAMI.
  fleet_runners_app_key_kv_secret_id = "https://${local.derived.fleet_kv_name}.vault.azure.net/secrets/${local.github_app_fleet_runners.private_key_kv_secret}"
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
# message when required runner networking IDs or GH App identifiers
# are missing. Mirrors the precondition pattern used on the tfstate PE
# in main.state.tf.

resource "terraform_data" "runner_preconditions" {
  input = {
    runner_subnet_id        = local.networking.runner_subnet_id
    runner_acr_pe_subnet_id = local.networking.runner_acr_pe_subnet_id
    runner_acr_dns_zone_id  = local.networking.runner_acr_dns_zone_id
    app_id                  = local.github_app_fleet_runners.app_id
    installation_id         = local.github_app_fleet_runners.installation_id
  }

  lifecycle {
    precondition {
      condition     = local.networking.runner_subnet_id != null && local.networking.runner_subnet_id != ""
      error_message = "networking.runner.subnet_id must be set in clusters/_fleet.yaml before applying bootstrap/fleet. See docs/adoption.md §5.1."
    }
    precondition {
      condition     = local.networking.runner_acr_pe_subnet_id != null && local.networking.runner_acr_pe_subnet_id != ""
      error_message = "networking.runner.container_registry_pe_subnet_id must be set in clusters/_fleet.yaml before applying bootstrap/fleet. See docs/adoption.md §5.1."
    }
    precondition {
      condition     = local.networking.runner_acr_dns_zone_id != null && local.networking.runner_acr_dns_zone_id != ""
      error_message = "networking.runner.container_registry_private_dns_zone_id must be set in clusters/_fleet.yaml (central privatelink.azurecr.io zone). See docs/adoption.md §5.1."
    }
    precondition {
      condition     = local.github_app_fleet_runners.app_id != null && local.github_app_fleet_runners.app_id != "" && local.github_app_fleet_runners.installation_id != null && local.github_app_fleet_runners.installation_id != ""
      error_message = "github_app.fleet_runners.{app_id, installation_id} must be set in clusters/_fleet.yaml before applying bootstrap/fleet. Run ./init-gh-apps.sh first. See docs/adoption.md §4 + §5.2."
    }
  }
}

# --- Runner pool (vendored AVM module with local extensions) -----------------

module "runner" {
  source     = "../../modules/cicd-runners"
  depends_on = [terraform_data.runner_preconditions]

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
  # BYO central DNS: the `privatelink.azurecr.io` zone pre-exists (typically
  # in the hub connectivity sub, symmetric with the tfstate PE's
  # `privatelink.blob.core.windows.net`). We tell the module NOT to create
  # a zone, and point it at the central one so the PE's DNS zone group
  # registers the A record there. No VNet→zone link is created by this
  # module, and therefore no `virtual_network_id` input is required.
  use_private_networking                               = true
  virtual_network_creation_enabled                     = false
  container_app_subnet_id                              = local.networking.runner_subnet_id
  container_registry_private_endpoint_subnet_id        = local.networking.runner_acr_pe_subnet_id
  container_registry_private_dns_zone_creation_enabled = false
  container_registry_dns_zone_id                       = local.networking.runner_acr_dns_zone_id

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
