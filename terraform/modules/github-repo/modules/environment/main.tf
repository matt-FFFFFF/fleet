# -----------------------------------------------------------------------------
# Environment
# -----------------------------------------------------------------------------

resource "github_repository_environment" "this" {
  repository          = var.repository
  environment         = var.environment
  wait_timer          = var.wait_timer
  can_admins_bypass   = var.can_admins_bypass
  prevent_self_review = var.prevent_self_review

  dynamic "reviewers" {
    for_each = var.reviewers != null ? [var.reviewers] : []
    content {
      teams = reviewers.value.teams
      users = reviewers.value.users
    }
  }

  dynamic "deployment_branch_policy" {
    for_each = var.deployment_policy != null ? [var.deployment_policy] : []
    content {
      protected_branches     = deployment_branch_policy.value.protected_branches
      custom_branch_policies = deployment_branch_policy.value.custom_branch_policies
    }
  }
}

# -----------------------------------------------------------------------------
# Environment variables
# -----------------------------------------------------------------------------

resource "github_actions_environment_variable" "this" {
  for_each = var.variables

  repository    = var.repository
  environment   = github_repository_environment.this.environment
  variable_name = each.value.name
  value         = each.value.value
}

# -----------------------------------------------------------------------------
# Environment secrets (names only — values managed externally)
# -----------------------------------------------------------------------------

resource "github_actions_environment_secret" "this" {
  for_each = var.secrets

  repository      = var.repository
  environment     = github_repository_environment.this.environment
  secret_name     = each.value.name
  plaintext_value = "REPLACE_ME"

  lifecycle {
    ignore_changes = [plaintext_value]
  }
}

# -----------------------------------------------------------------------------
# Custom deployment policies (branches and tags)
# -----------------------------------------------------------------------------

locals {
  deployment_policies = merge(
    { for bp in var.branch_policies : "branch:${bp}" => { branch_pattern = bp, tag_pattern = null } },
    { for tp in var.tag_policies : "tag:${tp}" => { branch_pattern = null, tag_pattern = tp } }
  )
}

resource "github_repository_environment_deployment_policy" "this" {
  for_each = local.deployment_policies

  repository     = var.repository
  environment    = github_repository_environment.this.environment
  branch_pattern = each.value.branch_pattern
  tag_pattern    = each.value.tag_pattern
}

# -----------------------------------------------------------------------------
# Azure identity
# -----------------------------------------------------------------------------

locals {
  # Whether to use the default GitHub OIDC subject format.
  use_default_subject = (
    var.actions_oidc_subject_claims == null ||
    var.actions_oidc_subject_claims.use_default
  )

  # Default format: repo:<owner>/<repo>:environment:<env-name>
  default_subject = "repo:${var.repository_full_name}:environment:${var.environment}"

  # Custom format: key:value pairs joined with ":"
  # e.g. repository_owner_id:6844498:repository_id:760046975:environment:staging
  # The "environment" key uses the actual environment name; other keys use the
  # resolved values from oidc_subject_claim_values. Non-`environment` keys
  # that are not present in `oidc_subject_claim_values` are replaced with a
  # sentinel so the resulting precondition below fails with a clear message
  # instead of a bare "Invalid index" error.
  # Non-`environment` keys in `include_claim_keys` must resolve to a
  # non-empty string via `oidc_subject_claim_values`. A missing key, a null
  # value, or an empty string all count as "missing" — any of these would
  # produce an invalid federated-credential subject (e.g. a stray
  # `::` segment from an empty value).
  missing_claim_keys = !local.use_default_subject ? [
    for key in var.actions_oidc_subject_claims.include_claim_keys :
    key if key != "environment" && (
      !contains(keys(var.oidc_subject_claim_values), key) ||
      try(var.oidc_subject_claim_values[key], null) == null ||
      try(var.oidc_subject_claim_values[key], "") == ""
    )
  ] : []

  custom_subject = !local.use_default_subject ? join(":", flatten([
    for key in var.actions_oidc_subject_claims.include_claim_keys :
    [key, key == "environment" ? var.environment : lookup(var.oidc_subject_claim_values, key, "")]
  ])) : ""

  # Final subject: explicit override > auto-constructed
  federated_subject = (
    var.identity != null
    ? coalesce(var.identity.subject, local.use_default_subject ? local.default_subject : local.custom_subject)
    : ""
  )
}

resource "azapi_resource" "identity" {
  count = var.identity != null ? 1 : 0

  type      = "Microsoft.ManagedIdentity/userAssignedIdentities@2023-01-31"
  parent_id = var.identity.parent_id
  name      = var.identity.name
  location  = var.identity.location

  body = {}

  response_export_values = [
    "properties.principalId",
    "properties.clientId",
    "properties.tenantId",
  ]
}

resource "azapi_resource" "federated_identity_credential" {
  count = var.identity != null ? 1 : 0

  type      = "Microsoft.ManagedIdentity/userAssignedIdentities/federatedIdentityCredentials@2023-01-31"
  parent_id = azapi_resource.identity[0].id
  name      = coalesce(try(var.identity.fic_name, null), var.environment)

  body = {
    properties = {
      issuer    = "https://token.actions.githubusercontent.com"
      subject   = local.federated_subject
      audiences = var.identity.audiences
    }
  }

  response_export_values = []

  lifecycle {
    precondition {
      condition     = length(local.missing_claim_keys) == 0
      error_message = "actions_oidc_subject_claims.include_claim_keys references ${jsonencode(local.missing_claim_keys)} but those keys are absent, null, or empty in oidc_subject_claim_values. Every non-`environment` claim key must map to a non-empty string."
    }
  }
}

# -----------------------------------------------------------------------------
# Azure role assignments
#
# Role-assignment resource names are Azure-scope GUIDs; deriving them
# deterministically from (role_key, scope, principalId) via `uuidv5` matches
# the repo-wide convention (see terraform/stages/0-fleet/main.kv.tf and
# terraform/bootstrap/environment/main.identities.tf) and makes IDs stable
# across recreations/imports.
# -----------------------------------------------------------------------------

resource "azapi_resource" "role_assignment" {
  for_each = var.role_assignments

  type      = "Microsoft.Authorization/roleAssignments@2022-04-01"
  parent_id = each.value.scope
  name = uuidv5(
    "url",
    "${each.key}/${each.value.scope}/${azapi_resource.identity[0].output.properties.principalId}",
  )

  body = {
    properties = {
      roleDefinitionId = each.value.role_definition_id
      principalId      = azapi_resource.identity[0].output.properties.principalId
      principalType    = "ServicePrincipal"
      condition        = each.value.condition
      conditionVersion = each.value.condition_version
    }
  }

  response_export_values = []
}
