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
  # that asserts it exists in _fleet.yaml.envs before any evaluation
  # of locals/providers/resources.
  environment = local.fleet_doc.envs[var.env]
  envs        = module.identity.envs
  observ      = local.fleet_doc.observability
  dns         = local.fleet_doc.dns

  # Location for env-scope non-cluster resources (RGs, observability stack,
  # env UAMI). Priority:
  #   1. explicit var.location override;
  #   2. for env=mgmt — envs.mgmt.location (PLAN §3.1; single location for
  #      mgmt-only non-cluster resources);
  #   3. for non-mgmt — first region declared under
  #      networking.envs.<env>.regions (arbitrary but deterministic);
  #      multi-region envs run this stage once and pick the first region
  #      as the home for the env-scope observability stack.
  location = (
    var.location != "" ? var.location :
    var.env == "mgmt" ? local.envs.mgmt.location :
    sort(keys(try(local.fleet_doc.networking.envs[var.env].regions, {})))[0]
  )

  derived = module.identity.derived

  # PLAN §3.4 networking. `networking_derived.envs` is keyed
  # "<env>/<region>"; downstream consumers in main.network.tf /
  # main.peering.tf re-key per-env to bare region names. `networking_central`
  # carries the central BYO PDZ ids + adopter hub VNet id.
  networking_derived = module.identity.networking_derived
  networking_central = module.identity.networking_central
}
