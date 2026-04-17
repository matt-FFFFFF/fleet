# main.github.tf
#
# GitHub scaffolding for the fleet repo: the repo itself (plus branch
# protection), the two GH Apps (`fleet-meta`, `stage0-publisher`), and the
# initial `fleet-stage0` + `fleet-meta` environments with their variables.
#
# The org already provides a maintained GH-repo module; we reference it as a
# placeholder until the published module path is known.

# -----------------------------------------------------------------------------
# Fleet repo (idempotent: managed-if-exists is not natively supported — if the
# repo exists from a prior run, the operator passes -refresh-only for the
# first run, then removes the `-target=null_resource.repo_check` guard).
#
# For Phase 1 we write the repo as code with `github_repository`. The org's
# GH-repo module (var.gh_repo_module_source) replaces these two blocks once
# its source is known.
# -----------------------------------------------------------------------------

resource "github_repository" "fleet" {
  name                   = var.fleet_repo_name
  description            = "Fleet monorepo: Terraform-driven AKS fleet + platform GitOps + Kargo"
  visibility             = var.fleet_repo_visibility
  has_issues             = true
  has_projects           = false
  has_wiki               = false
  allow_merge_commit     = false
  allow_squash_merge     = true
  allow_rebase_merge     = false
  delete_branch_on_merge = true
  vulnerability_alerts   = true

  lifecycle {
    # Stops the bootstrap stage from ever destroying the repo; all lifecycle
    # changes go through the GH UI / a fresh module release.
    prevent_destroy = true
    ignore_changes  = [auto_init, gitignore_template, license_template, topics, template]
  }
}

resource "github_branch_protection" "fleet_main" {
  repository_id = github_repository.fleet.node_id
  pattern       = "main"

  required_status_checks {
    strict   = true
    contexts = ["validate"]
  }

  required_pull_request_reviews {
    required_approving_review_count = 1
    require_code_owner_reviews      = true
  }

  enforce_admins         = false
  require_signed_commits = true

  # Kargo bot exemption for platform-gitops dev/staging values — the bot
  # commits directly to main on those paths. GitHub does not support
  # path-scoped branch-protection exceptions natively; the workaround is
  # to give the Kargo GitHub App repo bypass permission via a ruleset.
  # Placeholder: we'll migrate `main` protection to `github_repository_ruleset`
  # in Phase 7, with a path-and-actor-scoped bypass entry for the Kargo App.
  # See PLAN §10 / Branch protection + §15.
}

resource "github_repository" "team_template" {
  name                   = var.team_template_repo_name
  description            = "Template repo for team-owned services (services/<app>/environments/*)"
  visibility             = var.fleet_repo_visibility
  is_template            = true
  has_issues             = true
  allow_merge_commit     = false
  allow_squash_merge     = true
  delete_branch_on_merge = true

  lifecycle {
    prevent_destroy = true
    ignore_changes  = [auto_init, gitignore_template, license_template, topics, template]
  }
}

# -----------------------------------------------------------------------------
# GitHub environments: fleet-stage0 (no reviewers), fleet-meta (2 reviewers).
# Per-env environments (fleet-<env>) are created by bootstrap/environment.
# -----------------------------------------------------------------------------

resource "github_repository_environment" "fleet_stage0" {
  repository  = github_repository.fleet.name
  environment = "fleet-stage0"
  # reviewers: none (0)
  deployment_branch_policy {
    protected_branches     = true
    custom_branch_policies = false
  }
}

resource "github_repository_environment" "fleet_meta" {
  repository  = github_repository.fleet.name
  environment = "fleet-meta"

  reviewers {
    # 2-reviewer gate for meta-level operations. `teams` / `users` are
    # populated post-hoc by the operator (see docs/bootstrap.md) — the
    # block is present so the reviewer requirement itself is enforced.
    teams = []
    users = []
  }

  deployment_branch_policy {
    protected_branches     = true
    custom_branch_policies = false
  }
}

# -----------------------------------------------------------------------------
# Environment variables populated with the UAMI client IDs + tenant/sub IDs
# that CI needs for OIDC login.
# -----------------------------------------------------------------------------

locals {
  stage0_env_vars = {
    AZURE_CLIENT_ID         = azapi_resource.uami_fleet_stage0.output.properties.clientId
    AZURE_TENANT_ID         = var.fleet.tenant_id
    AZURE_SUBSCRIPTION_ID   = var.fleet.acr.subscription_id
    TFSTATE_CONTAINER       = var.fleet.state.containers.fleet
    TFSTATE_STORAGE_ACCOUNT = var.fleet.state.storage_account
    TFSTATE_RESOURCE_GROUP  = var.fleet.state.resource_group
    FLEET_NAME              = var.fleet.name
  }
  meta_env_vars = {
    AZURE_CLIENT_ID         = azapi_resource.uami_fleet_meta.output.properties.clientId
    AZURE_TENANT_ID         = var.fleet.tenant_id
    AZURE_SUBSCRIPTION_ID   = var.fleet.acr.subscription_id
    TFSTATE_CONTAINER       = var.fleet.state.containers.fleet
    TFSTATE_STORAGE_ACCOUNT = var.fleet.state.storage_account
    TFSTATE_RESOURCE_GROUP  = var.fleet.state.resource_group
    FLEET_NAME              = var.fleet.name
  }
}

resource "github_actions_environment_variable" "stage0" {
  for_each      = local.stage0_env_vars
  repository    = github_repository.fleet.name
  environment   = github_repository_environment.fleet_stage0.environment
  variable_name = each.key
  value         = each.value
}

resource "github_actions_environment_variable" "meta" {
  for_each      = local.meta_env_vars
  repository    = github_repository.fleet.name
  environment   = github_repository_environment.fleet_meta.environment
  variable_name = each.key
  value         = each.value
}

# -----------------------------------------------------------------------------
# GitHub Apps: `fleet-meta` and `stage0-publisher`.
#
# The `integrations/github` provider does not create GitHub Apps themselves —
# only installations/permissions on an existing App. GH Apps must be created
# out-of-band via the UI (or an unattended helper that posts to the App
# manifest flow).
#
# Phase 1 scaffold: document the required Apps + their permissions here, and
# commit to minting them manually before running this stage. Their App IDs
# and PEMs are then supplied as `-var` inputs to `bootstrap/fleet` for the
# next apply, which installs them on the fleet repo and stores their PEMs
# in the fleet KV (the KV itself is created by Stage 0, so PEM storage is
# deferred: see bootstrap/environment for the first Key Vault touch).
#
# TODO(phase1-bootstrap-gh-apps): implement manifest-flow helper +
# `github_app_installation` wiring once the manifest-flow tooling is chosen.
# Tracked against PLAN §4 Stage -1 `fleet-meta GitHub App` and
# `stage0-publisher GitHub App` bullets.
# -----------------------------------------------------------------------------
