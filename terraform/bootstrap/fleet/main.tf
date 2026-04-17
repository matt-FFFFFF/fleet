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
  _fleet_yaml_path = "${path.module}/../../../clusters/_fleet.yaml"
  _fleet_doc       = yamldecode(file(local._fleet_yaml_path))

  fleet        = local._fleet_doc.fleet
  environments = local._fleet_doc.environments
  aad          = local._fleet_doc.aad
  observ       = local._fleet_doc.observability
  dns          = local._fleet_doc.dns

  # Derived names (see docs/naming.md; must match terraform/config-loader/load.sh).
  derived = {
    state_storage_account = coalesce(
      try(local._fleet_doc.state.storage_account_name_override, ""),
      substr("st${local.fleet.name}tfstate", 0, 24),
    )
    state_resource_group = local._fleet_doc.state.resource_group
    state_container      = local._fleet_doc.state.containers.fleet
    state_subscription   = local._fleet_doc.state.subscription_id

    acr_name = coalesce(
      try(local._fleet_doc.acr.name_override, ""),
      "acr${local.fleet.name}shared",
    )
    acr_resource_group  = local._fleet_doc.acr.resource_group
    acr_subscription_id = local._fleet_doc.acr.subscription_id
    acr_location        = local._fleet_doc.acr.location

    fleet_kv_name = coalesce(
      try(local._fleet_doc.keyvault.name_override, ""),
      substr("kv-${local.fleet.name}-fleet", 0, 24),
    )

    fleet_stage0_fic_subject = var.fleet_stage0_fic_subject != "" ? var.fleet_stage0_fic_subject : "repo:${local.fleet.github_org}/${local.fleet.github_repo}:environment:fleet-stage0"
    fleet_meta_fic_subject   = var.fleet_meta_fic_subject != "" ? var.fleet_meta_fic_subject : "repo:${local.fleet.github_org}/${local.fleet.github_repo}:environment:fleet-meta"
  }
}
