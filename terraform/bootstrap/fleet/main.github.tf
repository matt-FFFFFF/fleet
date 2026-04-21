# main.github.tf
#
# GitHub scaffolding for the fleet repo, delivered via the vendored
# `terraform/modules/github-repo` module.
#
# Two module calls: one for the fleet monorepo itself (already exists on
# GitHub from the `Use this template` flow, adopted into state via an import
# block), and one for the team-repo-template repo (created fresh).
#
# The fleet-repo call also owns:
#   * the `fleet-stage0` + `fleet-meta` GitHub Actions environments,
#   * each environment's UAMI + federated credential + env-scoped RBAC,
#   * the `main`-branch ruleset (replaces the legacy
#     `github_branch_protection` resource; Kargo-bot bypass is deferred to
#     PLAN §7 / §15).

# -----------------------------------------------------------------------------
# Azure role-definition IDs used by the `identity_role_assignments` map
# below. Declared up-front so the module call reads top-to-bottom.
# -----------------------------------------------------------------------------

locals {
  role_def_contributor_acr_sub        = "/subscriptions/${local.derived.acr_subscription_id}/providers/Microsoft.Authorization/roleDefinitions/${local.role_contributor}"
  role_def_blob_contributor_state_sub = "/subscriptions/${local.derived.state_subscription}/providers/Microsoft.Authorization/roleDefinitions/${local.role_blob_data_ctrb}"
}

# -----------------------------------------------------------------------------
# Fleet monorepo + its two bootstrap environments.
#
# The repo already exists (created by `Use this template` before bootstrap
# ran). The `import` block below adopts it into state on the first apply and
# is a no-op thereafter — safe to leave in source.
# -----------------------------------------------------------------------------

import {
  to = module.fleet_repo.github_repository.this[0]
  id = local.fleet.github_repo
}

module "fleet_repo" {
  source = "../../modules/github-repo"

  name        = local.fleet.github_repo
  description = "Fleet monorepo: Terraform-driven AKS fleet + platform GitOps + Kargo"
  visibility  = var.fleet_repo_visibility

  has_issues   = true
  has_projects = false
  has_wiki     = false

  allow_merge_commit     = false
  allow_squash_merge     = true
  allow_rebase_merge     = false
  delete_branch_on_merge = true
  vulnerability_alerts   = true

  # Template instantiation already produced the initial commit; don't ask the
  # provider to create another.
  auto_init = false

  # OIDC subject template: use ID-based claims (owner ID + repo ID +
  # environment) rather than the name-based default
  # (`repo:<owner>/<repo>:environment:<env>`). IDs are immutable, so
  # renaming the org or the repo cannot silently invalidate federated
  # credentials on Azure. Matches the upstream module default.
  actions_oidc_subject_claims = {
    use_default = false
    include_claim_keys = [
      "repository_owner_id",
      "repository_id",
      "environment",
    ]
  }

  environments = {
    stage0 = {
      environment = "fleet-stage0"
      # reviewers: none (0 reviewers required — stage-0 runs unattended
      # under repo-admin-only bypass).
      deployment_policy = { protected_branches = true, custom_branch_policies = false }
      # `variables` intentionally left at default `{}` here; env variables
      # that reference the module's own UAMI output (client_id) are set by
      # `github_actions_environment_variable.stage0_*` below to break the
      # otherwise-inevitable module-call-to-child-output cycle.

      identity = {
        name      = "uami-fleet-stage0"
        parent_id = azapi_resource.rg_fleet_shared.id
        location  = local.derived.acr_location
        # Preserve the legacy FIC name (`gh-fleet-stage0`) so the refactor
        # does not cause a state rename.
        fic_name = "gh-fleet-stage0"
        # `subject` deliberately omitted — the submodule auto-builds
        # `repository_owner_id:<id>:repository_id:<id>:environment:fleet-stage0`
        # from the root module's `actions_oidc_subject_claims` config.
      }

      identity_role_assignments = {
        rg_contrib = {
          role_definition_id = local.role_def_contributor_acr_sub
          scope              = azapi_resource.rg_fleet_shared.id
        }
        blob_contrib = {
          role_definition_id = local.role_def_blob_contributor_state_sub
          scope              = azapi_resource.state_container_fleet.id
        }
      }
    }

    meta = {
      environment = "fleet-meta"
      # 2-reviewer gate for meta-level operations. `teams` / `users` are
      # populated post-hoc by the operator (see docs/bootstrap.md) — the
      # block is present so the reviewer requirement itself is enforced.
      reviewers         = { teams = [], users = [] }
      deployment_policy = { protected_branches = true, custom_branch_policies = false }
      # See stage0 above re: `variables`.

      identity = {
        name      = "uami-fleet-meta"
        parent_id = azapi_resource.rg_fleet_shared.id
        location  = local.derived.acr_location
        fic_name  = "gh-fleet-meta"
        # `subject` deliberately omitted — see fleet-stage0 above.
      }

      identity_role_assignments = {
        blob_contrib = {
          role_definition_id = local.role_def_blob_contributor_state_sub
          scope              = azapi_resource.state_container_fleet.id
        }
      }
    }
  }

  # `main`-branch protection delivered via repository ruleset (replaces the
  # legacy `github_branch_protection` resource). Kargo-bot bypass for the
  # platform-gitops dev/staging values path is deferred to PLAN §10 / §15 —
  # needs the Kargo GitHub App ID which is not provisioned yet.
  rulesets = {
    main = {
      name        = "main-branch-protection"
      enforcement = "active"
      target      = "branch"
      conditions = {
        ref_name = {
          include = ["~DEFAULT_BRANCH"]
          exclude = []
        }
      }
      rules = {
        non_fast_forward    = true
        required_signatures = true
        pull_request = {
          required_approving_review_count = 1
          require_code_owner_review       = true
          # The GitHub provider's ruleset schema requires at least one
          # entry here. The repo resource above sets allow_squash_merge=true
          # and disables merge commits + rebase merges, so `squash` is the
          # only method both allowed and consistent with the rest of the
          # config.
          allowed_merge_methods = ["squash"]
        }
        required_status_checks = {
          strict_required_status_checks_policy = true
          required_check = [
            { context = "validate" },
          ]
        }
      }
      bypass_actors = []
    }
  }
}

# -----------------------------------------------------------------------------
# Team-repo template repo — the source for team-owned service repos
# instantiated by `bootstrap/team`.
# -----------------------------------------------------------------------------

module "team_template_repo" {
  source = "../../modules/github-repo"

  name        = local.fleet.team_template_repo
  description = "Template repo for team-owned services (services/<app>/environments/*)"
  visibility  = var.fleet_repo_visibility

  is_template = true
  has_issues  = true

  allow_merge_commit     = false
  allow_squash_merge     = true
  delete_branch_on_merge = true
}

# -----------------------------------------------------------------------------
# GitHub Apps: `fleet-meta` and `stage0-publisher`.
#
# The `integrations/github` provider does not create GitHub Apps themselves —
# only installations/permissions on an existing App. GH Apps must be created
# out-of-band via the UI or via the `init-gh-apps.sh` manifest-flow helper
# at the repo root (PLAN §16.4, implemented).
#
# The helper creates all three Apps (`fleet-meta`, `stage0-publisher`,
# `fleet-runners`), records their installation metadata, and writes
# `./.gh-apps.auto.tfvars` for Stage 0 to consume. It also patches
# `clusters/_fleet.yaml` with `github_app.fleet_runners.{app_id,
# installation_id}` so this stage's runner module validation passes.
# The installation's repository selection must include the fleet repo
# (`local.fleet.github_repo`); the helper does not enforce this, so a
# mis-scoped install will surface here or in Stage 0 rather than during
# `init-gh-apps.sh` itself.
#
# TODO(phase2-stage0-gh-apps): declare matching `variable` blocks in
# terraform/stages/0-fleet/ and wire tf-apply.yaml to symlink the tfvars
# overlay into that stage's working directory.
# -----------------------------------------------------------------------------

# -----------------------------------------------------------------------------
# Environment variables populated with the UAMI client IDs + tenant/sub IDs
# that CI needs for OIDC login.
#
# Declared at the callsite (outside `module.fleet_repo`) to break the cycle
# that would otherwise form by feeding the module's own
# `environments[*].identity.client_id` output back into its `variables` input.
# -----------------------------------------------------------------------------

locals {
  stage0_env_vars = {
    AZURE_CLIENT_ID         = module.fleet_repo.environments["stage0"].identity.client_id
    AZURE_TENANT_ID         = local.fleet.tenant_id
    AZURE_SUBSCRIPTION_ID   = local.derived.acr_subscription_id
    TFSTATE_CONTAINER       = local.derived.state_container
    TFSTATE_STORAGE_ACCOUNT = local.derived.state_storage_account
    TFSTATE_RESOURCE_GROUP  = local.derived.state_resource_group
    FLEET_NAME              = local.fleet.name
    # PLAN §3.4: Stage 0 lands the fleet ACR PE in the mgmt VNet's
    # `snet-pe-fleet` co-located with `acr.location`. The tf-apply.yaml
    # workflow parses this JSON map and passes it in as the
    # `mgmt_pe_fleet_subnet_ids` tfvar. Also published on the
    # `fleet-meta` env below for observability/diagnostics.
    MGMT_PE_FLEET_SUBNET_IDS = jsonencode(local.mgmt_snet_pe_fleet_ids)
  }
  meta_env_vars = {
    AZURE_CLIENT_ID         = module.fleet_repo.environments["meta"].identity.client_id
    AZURE_TENANT_ID         = local.fleet.tenant_id
    AZURE_SUBSCRIPTION_ID   = local.derived.acr_subscription_id
    TFSTATE_CONTAINER       = local.derived.state_container
    TFSTATE_STORAGE_ACCOUNT = local.derived.state_storage_account
    TFSTATE_RESOURCE_GROUP  = local.derived.state_resource_group
    FLEET_NAME              = local.fleet.name
    # PLAN §3.4: per-region mgmt networking ids published as JSON-encoded
    # `{ region => resource_id }` maps. Downstream workflows parse with
    # `fromJSON(vars.MGMT_*)` and index by the cluster's region (or, for
    # non-mgmt envs, by the mgmt region resolved from the cluster's
    # region via same-region-else-first rule — see
    # modules/fleet-identity/main.tf `mgmt_regions` / config-loader/load.sh).
    #
    #   MGMT_VNET_RESOURCE_IDS   → bootstrap/environment (env=mgmt branch +
    #                              cross-env reverse-peering target);
    #                              stages/1-cluster (DNS zone VNet link in
    #                              the cluster's region)
    #   MGMT_PE_FLEET_SUBNET_IDS → observability / diagnostics (subnet is
    #                              consumed internally by bootstrap/fleet)
    #   MGMT_RUNNERS_SUBNET_IDS  → diagnostics (subnet is consumed
    #                              internally by bootstrap/fleet)
    MGMT_VNET_RESOURCE_IDS   = jsonencode(local.mgmt_vnet_ids)
    MGMT_PE_FLEET_SUBNET_IDS = jsonencode(local.mgmt_snet_pe_fleet_ids)
    MGMT_RUNNERS_SUBNET_IDS  = jsonencode(local.mgmt_snet_runners_ids)
  }
}

resource "github_actions_environment_variable" "stage0" {
  for_each      = local.stage0_env_vars
  repository    = local.fleet.github_repo
  environment   = module.fleet_repo.environments["stage0"].environment.environment
  variable_name = each.key
  value         = each.value
}

resource "github_actions_environment_variable" "meta" {
  for_each      = local.meta_env_vars
  repository    = local.fleet.github_repo
  environment   = module.fleet_repo.environments["meta"].environment.environment
  variable_name = each.key
  value         = each.value
}
