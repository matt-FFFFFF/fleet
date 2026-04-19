# fleet-identity/main.tf
#
# Derivation rules. Single source alongside:
#   - docs/naming.md               (canonical spec)
#   - terraform/config-loader/load.sh (shell impl consumed by Stage 1/2)
# Change all three together; CI does not (yet) diff them.

locals {
  fleet = var.fleet_doc.fleet

  # Derived names. `coalesce(... "")` pattern lets an explicit override
  # win; when the override is empty/absent the formula result is used.
  # `substr(..., 0, 24)` enforces Azure's 24-char ceiling on KV and SA
  # names. Formulas mirror docs/naming.md §"Derived names".
  derived = {
    # ----- tfstate storage ------------------------------------------------
    state_storage_account = coalesce(
      try(var.fleet_doc.state.storage_account_name_override, ""),
      substr("st${local.fleet.name}tfstate", 0, 24),
    )
    state_resource_group = var.fleet_doc.state.resource_group
    state_container      = var.fleet_doc.state.containers.fleet
    state_subscription   = var.fleet_doc.state.subscription_id

    # ----- fleet ACR ------------------------------------------------------
    acr_name = coalesce(
      try(var.fleet_doc.acr.name_override, ""),
      "acr${local.fleet.name}shared",
    )
    acr_resource_group  = var.fleet_doc.acr.resource_group
    acr_subscription_id = var.fleet_doc.acr.subscription_id
    acr_location        = var.fleet_doc.acr.location

    # ----- fleet Key Vault ------------------------------------------------
    fleet_kv_name = coalesce(
      try(var.fleet_doc.keyvault.name_override, ""),
      substr("kv-${local.fleet.name}-fleet", 0, 24),
    )
    fleet_kv_resource_group = try(var.fleet_doc.keyvault.resource_group, var.fleet_doc.acr.resource_group)
    fleet_kv_location       = try(var.fleet_doc.keyvault.location, local.fleet.primary_region)
  }

  # Private-networking identifiers. All try-guarded so older / partial
  # `_fleet.yaml` docs (pre-networking-schema) remain parseable — an
  # adopter fills these in before the relevant apply.
  networking = {
    tfstate_pe_subnet_id           = try(var.fleet_doc.networking.tfstate.private_endpoint.subnet_id, null)
    tfstate_pe_private_dns_zone_id = try(var.fleet_doc.networking.tfstate.private_endpoint.private_dns_zone_id, null)
    runner_subnet_id               = try(var.fleet_doc.networking.runner.subnet_id, null)
    runner_acr_pe_subnet_id        = try(var.fleet_doc.networking.runner.container_registry_pe_subnet_id, null)
    runner_acr_dns_zone_id         = try(var.fleet_doc.networking.runner.container_registry_private_dns_zone_id, null)
    fleet_kv_pe_subnet_id          = try(var.fleet_doc.networking.fleet_kv.private_endpoint.subnet_id, null)
    fleet_kv_pe_dns_zone_id        = try(var.fleet_doc.networking.fleet_kv.private_endpoint.private_dns_zone_id, null)
  }

  # fleet-runners GitHub App (KEDA polling). See docs/adoption.md §4.
  github_app_fleet_runners = {
    app_id                = try(var.fleet_doc.github_app.fleet_runners.app_id, "")
    installation_id       = try(var.fleet_doc.github_app.fleet_runners.installation_id, "")
    private_key_kv_secret = try(var.fleet_doc.github_app.fleet_runners.private_key_kv_secret, "fleet-runners-app-pem")
  }
}
