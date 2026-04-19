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
#   2. Grant the runner UAMI `Key Vault Secrets User` on the fleet Key Vault
#      scope (fleet KV itself is created by Stage 0; role assignment here
#      is scope-by-id only, so applies cleanly before the KV exists).
#   3. Invoke the vendored ACA+KEDA runner module with:
#        - bring-your-own VNet (networking.*)
#        - no NAT / no public IP (UDR + hub firewall own egress)
#        - per-pool private ACR (module default)
#        - KV-reference for the GitHub App PEM (vendor extension — see
#          terraform/modules/cicd-runners/VENDORING.md §4)
#
# Stage 0 later seeds the PEM into the fleet KV under the secret name
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
  fleet_kv_id                        = "/subscriptions/${local.derived.acr_subscription_id}/resourceGroups/${local.derived.acr_resource_group}/providers/Microsoft.KeyVault/vaults/${local.derived.fleet_kv_name}"
  fleet_runners_app_key_kv_secret_id = "https://${local.derived.fleet_kv_name}.vault.azure.net/secrets/${local.github_app_fleet_runners.private_key_kv_secret}"

  # Azure built-in role GUID: Key Vault Secrets User.
  role_kv_secrets_user = "4633458b-17de-408a-b874-0445c86b69e6"
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

# --- Key Vault Secrets User on the fleet KV ----------------------------------
#
# Scope is referenced by id — the fleet KV itself does not yet exist at this
# stage; Stage 0 creates it and seeds `fleet-runners-app-pem`. The role
# assignment plans cleanly because azapi issues it as a PUT against
# Microsoft.Authorization/roleAssignments with the target scope as a
# string, not a resource reference that must resolve at plan time.

resource "azapi_resource" "runner_kv_secrets_user" {
  type      = "Microsoft.Authorization/roleAssignments@2022-04-01"
  name      = uuidv5("url", "${local.fleet_kv_id}|${local.runner_uami_name}|kv-secrets-user")
  parent_id = local.fleet_kv_id

  body = {
    properties = {
      roleDefinitionId = "/subscriptions/${local.derived.acr_subscription_id}/providers/Microsoft.Authorization/roleDefinitions/${local.role_kv_secrets_user}"
      principalId      = azapi_resource.runner_uami.output.properties.principalId
      principalType    = "ServicePrincipal"
    }
  }

  lifecycle {
    ignore_changes = [name]
  }
}

# --- Runner pool (vendored AVM module with local extensions) -----------------

module "runner" {
  source = "../../modules/cicd-runners"

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
  use_private_networking                        = true
  virtual_network_creation_enabled              = false
  virtual_network_id                            = local.networking.vnet_id
  container_app_subnet_id                       = local.networking.runner_subnet_id
  container_registry_private_endpoint_subnet_id = local.networking.runner_acr_pe_subnet_id

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
