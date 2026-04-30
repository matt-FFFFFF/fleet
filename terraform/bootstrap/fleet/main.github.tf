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
#   * the `fleet-meta` GitHub Actions environment,
#   * the environment's UAMI + federated credential + env-scoped RBAC,
#   * the `main`-branch ruleset (replaces the legacy
#     `github_branch_protection` resource; Kargo-bot bypass is deferred to
#     PLAN §7 / §15).

# -----------------------------------------------------------------------------
# Azure role-definition IDs used by the `identity_role_assignments` map
# below. Declared up-front so the module call reads top-to-bottom.
# -----------------------------------------------------------------------------

locals {
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
    meta = {
      environment = "fleet-meta"
      # 2-reviewer gate for meta-level operations. `teams` / `users` are
      # populated post-hoc by the operator (see docs/bootstrap.md) — the
      # block is present so the reviewer requirement itself is enforced.
      reviewers         = { teams = [], users = [] }
      deployment_policy = { protected_branches = true, custom_branch_policies = false }
      # `variables` intentionally left at default `{}` here; env variables
      # that reference the module's own UAMI output (client_id) are set by
      # `github_actions_environment_variable.meta` below to break the
      # otherwise-inevitable module-call-to-child-output cycle.

      identity = {
        name      = "uami-fleet-meta"
        parent_id = azapi_resource.rg_fleet_shared.id
        location  = local.derived.acr_location
        fic_name  = "gh-fleet-meta"
        # `subject` deliberately omitted — the submodule auto-builds
        # `repository_owner_id:<id>:repository_id:<id>:environment:fleet-meta`
        # from the root module's `actions_oidc_subject_claims` config.
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
          # Each `validate.yaml` job emits its own check (the `name:` of
          # the job, not the workflow file name). GitHub does not
          # auto-aggregate them under a workflow-level status, so the
          # ruleset must list every required check explicitly. Adding
          # a new job to `validate.yaml` requires adding its `name:` here
          # and re-applying `bootstrap/fleet`.
          required_check = [
            { context = "terraform fmt" },
            { context = "tflint" },
            { context = "yamllint" },
            { context = "subnet slots" },
            { context = "naming parity" },
            { context = "schema lint" },
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
# GitHub Apps: `fleet-meta` and `fleet-runners`.
#
# The `integrations/github` provider does not create GitHub Apps themselves —
# only installations/permissions on an existing App. GH Apps must be created
# out-of-band via the UI or via the `init-gh-apps.sh` manifest-flow helper
# at the repo root (PLAN §16.4, implemented).
#
# The helper creates the two Apps (`fleet-meta`, `fleet-runners`),
# records their installation metadata in `./.gh-apps.state.json`, and
# writes a narrow per-module overlay at
# `terraform/bootstrap/fleet/.gh-apps.auto.tfvars` carrying
# `fleet_runners_app_pem` + `fleet_runners_app_pem_version` — the two
# variables this stage declares (see `variables.tf`). It also patches
# `clusters/_fleet.yaml` with `github_app.fleet_runners.{app_id,
# installation_id}` so this stage's runner module validation passes.
# The installation's repository selection must include the fleet repo
# (`local.fleet.github_repo`); the helper does not enforce this, so a
# mis-scoped install will surface here rather than during
# `init-gh-apps.sh` itself.
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
  meta_env_vars = {
    AZURE_CLIENT_ID         = module.fleet_repo.environments["meta"].identity.client_id
    AZURE_TENANT_ID         = local.fleet.tenant_id
    AZURE_SUBSCRIPTION_ID   = local.derived.acr_subscription_id
    TFSTATE_CONTAINER       = local.derived.state_container
    TFSTATE_STORAGE_ACCOUNT = local.derived.state_storage_account
    TFSTATE_RESOURCE_GROUP  = local.derived.state_resource_group
    FLEET_NAME              = local.fleet.name
    # principalId of `uami-fleet-meta`, consumed by `bootstrap/environment`
    # as `var.fleet_meta_principal_id` (no default; required). Wired into
    # the `env-bootstrap.yaml` workflow via
    # `TF_VAR_fleet_meta_principal_id: ${{ vars.FLEET_META_PRINCIPAL_ID }}`.
    FLEET_META_PRINCIPAL_ID = module.fleet_repo.environments["meta"].identity.principal_id

    # GH App coordinates for `env-bootstrap.yaml` / `team-bootstrap.yaml`:
    # the workflows fetch `fleet-meta-app-pem` from the runners KV and pass
    # it (with `FLEET_META_APP_CLIENT_ID`) to
    # `actions/create-github-app-token` to mint a short-lived
    # installation token. The action's `app-id` input is deprecated in
    # favour of `client-id`, so we publish the client ID. The KV secret
    # name comes from `_fleet.yaml.github_app.fleet_meta.private_key_kv_secret`
    # (default `fleet-meta-app-pem`); exposing it as a repo var keeps
    # the workflow free of hard-coded secret names.
    FLEET_META_APP_CLIENT_ID     = local.github_app_fleet_meta.client_id
    FLEET_META_APP_PEM_KV_SECRET = local.github_app_fleet_meta.private_key_kv_secret
    RUNNERS_KV_NAME              = local.derived.runners_kv_name

    # GitHub owner + repo numeric IDs, looked up by `bootstrap/fleet` via
    # `module.fleet_repo`'s `data.github_organization` / `data.github_user`
    # data sources (which Stage -1's locally-run operator credentials can
    # resolve). Republished here so `bootstrap/environment` (which runs
    # in CI as the fleet-meta App and lacks `Members: read` org access)
    # can build OIDC subject claim values without re-querying the org.
    FLEET_GITHUB_OWNER_ID = module.fleet_repo.actions_oidc_subject_claim_values.repository_owner_id
    FLEET_GITHUB_REPO_ID  = module.fleet_repo.actions_oidc_subject_claim_values.repository_id
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

resource "github_actions_environment_variable" "meta" {
  for_each      = local.meta_env_vars
  repository    = local.fleet.github_repo
  environment   = module.fleet_repo.environments["meta"].environment.environment
  variable_name = each.key
  value         = each.value
}
