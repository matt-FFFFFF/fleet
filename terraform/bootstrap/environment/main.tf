# bootstrap/environment
#
# Per-env scaffolding (see PLAN §4.1). Invoked by .github/workflows/env-bootstrap.yaml
# under the `fleet-meta` environment (2-reviewer gate), one run per env.
#
# Fleet identity is sourced from clusters/_fleet.yaml; only env-scope inputs
# are supplied as variables.
#
# Resources are split across:
#   main.state.tf         per-env state container
#   main.identities.tf    uami-fleet-<env> + FIC + env-scoped RBAC + meta sub RBAC
#   main.observability.tf NSP + AMW + DCE + Grafana + PE + Action Group
#   main.github.tf        fleet-<env> GH environment + variables

locals {
  fleet_yaml_path = "${path.module}/../../../clusters/_fleet.yaml"
  fleet_doc       = yamldecode(file(local.fleet_yaml_path))
}

# Derivation lives in the pure-function `modules/fleet-identity` module.
# Shared with `bootstrap/fleet`; testable in isolation. See docs/naming.md.
module "identity" {
  source    = "../../modules/fleet-identity"
  fleet_doc = local.fleet_doc
}

locals {
  fleet = module.identity.fleet
  # Direct lookup — var.env is guarded by a validation block in variables.tf
  # that asserts it exists in _fleet.yaml.environments before any evaluation
  # of locals/providers/resources.
  environment = local.fleet_doc.environments[var.env]
  observ      = local.fleet_doc.observability
  dns         = local.fleet_doc.dns

  location = var.location != "" ? var.location : local.fleet.primary_region

  derived = module.identity.derived

  # PLAN §3.4 networking. `networking_derived.envs` is keyed
  # "<env>/<region>"; downstream consumers in main.network.tf /
  # main.peering.tf re-key per-env to bare region names. `networking_central`
  # carries the central BYO PDZ ids + adopter hub VNet id.
  networking_derived = module.identity.networking_derived
  networking_central = module.identity.networking_central
}
