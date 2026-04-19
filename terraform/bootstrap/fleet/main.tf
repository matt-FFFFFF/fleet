# bootstrap/fleet
#
# Human-run, one-time (per PLAN §4 Stage -1 `bootstrap/fleet/`). Creates:
#
#   1. rg-fleet-tfstate + state SA + tfstate-fleet container
#   2. rg-fleet-shared (Stage 0 will land ACR + fleet KV here)
#   3. uami-fleet-stage0 + uami-fleet-meta + their FICs
#   4. Azure RBAC: fleet-stage0 Contributor on rg-fleet-shared + Blob
#      Contributor on tfstate-fleet; fleet-meta Blob Contributor on
#      tfstate-fleet. Subscription-scope assignments for fleet-meta are
#      deferred to bootstrap/environment (one per env subscription).
#   5. Entra `Application Administrator` on both UAMIs.
#   6. Fleet GitHub repo + branch protection; team-repo-template repo.
#   7. fleet-stage0 + fleet-meta GitHub environments with env variables.
#
# Files intentionally omitted from this stage (move to later stages):
#   - ACR, fleet KV → Stage 0
#   - Per-env state containers + env UAMIs → bootstrap/environment
#   - Fleet-meta GH App + stage0-publisher GH App minting → see main.github.tf
#     TODO comment; these are currently manual preconditions.

# All resources live in topic-specific files:
#   main.state.tf       state SA + container
#   main.identities.tf  UAMIs + FICs + RBAC + Entra role assignments
#   main.github.tf      repos + environments + variables

# -----------------------------------------------------------------------------
# Fleet identity is the yaml document produced by init-fleet.sh. All resources
# reference `local.fleet.*` / `local.derived.*` — never `var.fleet`.
# -----------------------------------------------------------------------------

locals {
  fleet_yaml_path = "${path.module}/../../../clusters/_fleet.yaml"
  fleet_doc       = yamldecode(file(local.fleet_yaml_path))

  fleet = local.fleet_doc.fleet

  # Derived names (see docs/naming.md; must match terraform/config-loader/load.sh).
  derived = {
    state_storage_account = coalesce(
      try(local.fleet_doc.state.storage_account_name_override, ""),
      substr("st${local.fleet.name}tfstate", 0, 24),
    )
    state_resource_group = local.fleet_doc.state.resource_group
    state_container      = local.fleet_doc.state.containers.fleet
    state_subscription   = local.fleet_doc.state.subscription_id

    acr_name = coalesce(
      try(local.fleet_doc.acr.name_override, ""),
      "acr${local.fleet.name}shared",
    )
    acr_resource_group  = local.fleet_doc.acr.resource_group
    acr_subscription_id = local.fleet_doc.acr.subscription_id
    acr_location        = local.fleet_doc.acr.location

    fleet_kv_name = coalesce(
      try(local.fleet_doc.keyvault.name_override, ""),
      substr("kv-${local.fleet.name}-fleet", 0, 24),
    )
  }

  # Private-networking identifiers read from _fleet.yaml.networking.
  # `try(...)` keeps older _fleet.yaml docs (pre-networking-schema) parseable
  # during validate — an adopter must fill these in before applying.
  networking = {
    vnet_id                        = try(local.fleet_doc.networking.vnet_id, null)
    tfstate_pe_subnet_id           = try(local.fleet_doc.networking.tfstate.private_endpoint.subnet_id, null)
    tfstate_pe_private_dns_zone_id = try(local.fleet_doc.networking.tfstate.private_endpoint.private_dns_zone_id, null)
    runner_subnet_id               = try(local.fleet_doc.networking.runner.subnet_id, null)
    runner_acr_pe_subnet_id        = try(local.fleet_doc.networking.runner.container_registry_pe_subnet_id, null)
  }

  # fleet-runners GitHub App (KEDA polling). See docs/adoption.md §4.
  github_app_fleet_runners = {
    app_id                = try(local.fleet_doc.github_app.fleet_runners.app_id, "")
    installation_id       = try(local.fleet_doc.github_app.fleet_runners.installation_id, "")
    private_key_kv_secret = try(local.fleet_doc.github_app.fleet_runners.private_key_kv_secret, "fleet-runners-app-pem")
  }
}
