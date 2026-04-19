# bootstrap/fleet
#
# Human-run, one-time (per PLAN §4 Stage -1 `bootstrap/fleet/`). Creates:
#
#   1. rg-fleet-tfstate + state SA + tfstate-fleet container (private endpoint)
#   2. rg-fleet-shared (Stage 0 will land the ACR here)
#   3. Fleet Key Vault + private endpoint + DNS A-record registration
#      (Stage 0 seeds Argo + GH App secrets into it)
#   4. uami-fleet-stage0 + uami-fleet-meta + uami-fleet-runners + FICs
#   5. Azure RBAC: fleet-stage0 Contributor on rg-fleet-shared + Blob
#      Contributor on tfstate-fleet; fleet-meta Blob Contributor on
#      tfstate-fleet; fleet-runners Key Vault Secrets User on the fleet KV.
#      Subscription-scope assignments for fleet-meta are deferred to
#      bootstrap/environment (one per env subscription).
#   6. Entra `Application Administrator` on both UAMIs.
#   7. Fleet GitHub repo + branch protection; team-repo-template repo.
#   8. fleet-stage0 + fleet-meta GitHub environments with env variables.
#   9. Self-hosted GitHub Actions runner pool (ACA + KEDA) with per-pool
#      private ACR, KV-reference for the GH App PEM.
#
# Files intentionally omitted from this stage (move to later stages):
#   - ACR → Stage 0
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
  networking               = module.identity.networking
  github_app_fleet_runners = module.identity.github_app_fleet_runners
}
