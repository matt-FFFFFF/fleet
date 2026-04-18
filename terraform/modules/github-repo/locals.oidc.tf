# -----------------------------------------------------------------------------
# OIDC subject claim key resolution
#
# Maps GitHub Actions OIDC claim keys to their actual values using data
# available from the github_repository resource (or data source when
# create_repository is false) and the github_organization or github_user
# data source (depending on owner_is_organization).
#
# Only claims that can be resolved at plan/apply time are included here.
# Runtime-only claims (actor, actor_id, environment, ref, sha, run_id,
# run_number, run_attempt, runner_environment, workflow, head_ref, base_ref,
# event_name, ref_type, job_workflow_ref) are excluded because their values
# are only known during workflow execution.
#
# Reference: https://docs.github.com/en/actions/concepts/security/openid-connect
# -----------------------------------------------------------------------------

locals {
  # Unified repo attributes: use the resource when creating, data source otherwise.
  oidc_repo = var.actions_oidc_subject_claims != null ? (
    var.create_repository ? github_repository.this[0] : data.github_repository.this[0]
  ) : null

  # Owner identity: use org data source for orgs, user data source for personal accounts.
  oidc_owner_login = var.actions_oidc_subject_claims != null ? (
    var.owner_is_organization ? data.github_organization.this[0].login : data.github_user.this[0].login
  ) : null

  oidc_owner_id = var.actions_oidc_subject_claims != null ? (
    var.owner_is_organization ? data.github_organization.this[0].id : data.github_user.this[0].id
  ) : null

  # All OIDC claim keys that can be resolved from Terraform-managed resources.
  oidc_resolvable_claim_keys = var.actions_oidc_subject_claims != null ? {
    repository            = local.oidc_repo.full_name
    repository_id         = tostring(local.oidc_repo.repo_id)
    repository_owner      = local.oidc_owner_login
    repository_owner_id   = local.oidc_owner_id
    repository_visibility = local.oidc_repo.visibility
  } : {}

  # Filter to only the claim keys requested in var.actions_oidc_subject_claims.
  # Keys that are runtime-only will not appear in the output.
  oidc_subject_claim_values = var.actions_oidc_subject_claims != null ? {
    for key in var.actions_oidc_subject_claims.include_claim_keys :
    key => local.oidc_resolvable_claim_keys[key]
    if contains(keys(local.oidc_resolvable_claim_keys), key)
  } : {}

  # Merge module-resolved values with user-supplied values for keys that cannot
  # be resolved at plan time (e.g. job_workflow_ref). Resolved values take
  # precedence (validation on the variable prevents overlap anyway).
  oidc_subject_claim_values_merged = merge(
    var.actions_oidc_subject_claim_values,
    local.oidc_subject_claim_values,
  )
}
