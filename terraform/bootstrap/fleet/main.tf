# bootstrap/fleet
#
# Human-run, one-time (per PLAN §4 Stage -1 `bootstrap/fleet/`). Creates:
#
#   1. rg-fleet-tfstate + state SA + tfstate-fleet container (private endpoint
#      landing in the co-located mgmt VNet's snet-pe-fleet subnet)
#   2. rg-fleet-shared (env=mgmt's `bootstrap/environment` lands the fleet
#      ACR here)
#   3. rg-fleet-runners + runners Key Vault + private endpoint (co-located
#      mgmt VNet snet-pe-fleet) + DNS registration in the central
#      privatelink.vaultcore.azure.net zone (seeds GH App PEMs via
#      `init-gh-apps.sh`)
#   4. uami-fleet-meta + uami-fleet-runners + FICs
#   5. Azure RBAC: fleet-meta Blob Contributor on tfstate-fleet;
#      fleet-meta Network Contributor on EACH mgmt env-region VNet (so
#      `bootstrap/environment` can carve cluster-workload subnets on
#      mgmt VNets and author reverse-half peerings from non-mgmt envs);
#      fleet-runners Key Vault Secrets User on the runners KV.
#      Subscription-scope assignments for fleet-meta are deferred to
#      bootstrap/environment (one per env subscription).
#   6. Argo + Kargo AAD app registrations + service principals + 2-year
#      RP `client_secret` values (operator-applied via interactive
#      `az login`; no UAMI Graph grant needed). On the second-pass
#      apply (with `var.mgmt_cluster_kv_id` set from the
#      `MGMT_CLUSTER_KV_ID` repo var published by Stage 1 mgmt), the
#      `client_secret` values are written into the mgmt cluster KV.
#      Repo-level GH Actions vars `ARGO_AAD_APP_ID`, `KARGO_AAD_APP_ID`,
#      `KARGO_AAD_APPLICATION_OBJECT_ID` published. See main.aad.tf.
#   7. Fleet GitHub repo + branch protection; team-repo-template repo.
#   8. fleet-meta GitHub environment with env variables, including
#      JSON-encoded MGMT_VNET_RESOURCE_IDS / MGMT_PE_FLEET_SUBNET_IDS /
#      MGMT_RUNNERS_SUBNET_IDS maps (consumed by `bootstrap/environment`
#      and stages/1-cluster per PLAN §3.4).
#   9. Self-hosted GitHub Actions runner pool (ACA + KEDA) in the
#      co-located mgmt VNet's snet-runners subnet, with per-pool
#      private ACR and KV-reference for the GH App PEM.
#  10. Mgmt env-region VNets (PLAN §3.4) — one per
#      `networking.envs.mgmt.regions.<region>` entry via
#      Azure/avm-ptn-alz-sub-vending/azure (N=1 per invocation, no
#      mesh, hub_peering to
#      `networking.envs.mgmt.regions.<region>.hub_network_resource_id`
#      when non-null; null opts out of hub peering).
#      Authors fleet-plane subnets only (snet-pe-fleet, snet-runners)
#      at the HIGH end of each VNet's /20; cluster-workload subnets
#      (snet-pe-env, api pool, nodes pool, node ASG, route table) on
#      the LOW end are carved by `bootstrap/environment`. NSGs
#      nsg-pe-fleet-<region> + nsg-runners-<region>. RG
#      rg-net-mgmt-<region>.
#
# Files intentionally omitted from this stage (owned elsewhere):
#   - Fleet ACR → `bootstrap/environment` env=mgmt
#   - Per-env state containers + env UAMIs → bootstrap/environment
#   - Env VNets + cluster-workload subnets on mgmt VNets + mgmt↔env
#     peerings + per-env node ASGs → bootstrap/environment
#   - Fleet-meta GH App minting → see main.github.tf TODO comment;
#     currently a manual precondition (`init-gh-apps.sh`).

# All resources live in topic-specific files:
#   main.state.tf       state SA + container + PE
#   main.kv.tf          fleet Key Vault + PE + RBAC
#   main.network.tf     mgmt env-region VNets + fleet-plane subnets + NSGs
#                       + hub peering (PLAN §3.4)
#   main.runner.tf      ACA+KEDA runner pool
#   main.identities.tf  UAMIs + FICs + RBAC + Entra role assignments
#   main.github.tf      repos + environments + variables

# -----------------------------------------------------------------------------
# Fleet identity is the yaml document produced by init-fleet.sh. All resources
# reference `local.fleet.*` / `local.derived.*` — never `var.fleet`.
# -----------------------------------------------------------------------------

locals {
  fleet_yaml_path = "${path.module}/../../../clusters/_fleet.yaml"
  fleet_doc       = yamldecode(file(local.fleet_yaml_path))
}

# Derivation (names, networking identifiers, GH-App coordinates) lives in
# the pure-function `modules/fleet-identity` module so it is (a) testable in
# isolation via `terraform test` and (b) shared with `bootstrap/environment`.
# See docs/naming.md for the contract; both callers must move in lockstep
# with `terraform/config-loader/load.sh`.
module "identity" {
  source    = "../../modules/fleet-identity"
  fleet_doc = local.fleet_doc
}

locals {
  fleet                    = module.identity.fleet
  derived                  = module.identity.derived
  networking_derived       = module.identity.networking_derived
  networking_central       = module.identity.networking_central
  github_app_fleet_runners = module.identity.github_app_fleet_runners
  github_app_fleet_meta    = module.identity.github_app_fleet_meta
}
