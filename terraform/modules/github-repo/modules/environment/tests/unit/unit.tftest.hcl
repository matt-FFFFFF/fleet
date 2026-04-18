# -----------------------------------------------------------------------------
# Unit tests for modules/environment
#
# These tests use provider mocking so no real GitHub resources are created.
# -----------------------------------------------------------------------------

mock_provider "github" {
  mock_resource "github_repository_environment" {
    defaults = {}
  }

  mock_resource "github_actions_environment_variable" {
    defaults = {
      created_at    = "2024-01-01T00:00:00Z"
      updated_at    = "2024-01-01T00:00:00Z"
      repository_id = 123456
    }
  }

  mock_resource "github_actions_environment_secret" {
    defaults = {
      created_at        = "2024-01-01T00:00:00Z"
      updated_at        = "2024-01-01T00:00:00Z"
      remote_updated_at = "2024-01-01T00:00:00Z"
      repository_id     = 123456
    }
  }

  mock_resource "github_repository_environment_deployment_policy" {
    defaults = {}
  }
}

mock_provider "azapi" {
  mock_resource "azapi_resource" {
    defaults = {
      id = "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/rg-mock/providers/Microsoft.ManagedIdentity/userAssignedIdentities/mock-identity"
      output = {
        properties = {
          principalId = "00000000-0000-0000-0000-000000000001"
          clientId    = "00000000-0000-0000-0000-000000000002"
          tenantId    = "00000000-0000-0000-0000-000000000003"
        }
      }
    }
  }
}

mock_provider "random" {}

# File-level variables applied to all run blocks unless overridden.
variables {
  repository  = "test-repo"
  environment = "test-env"
}

# =============================================================================
# Basic environment creation
# =============================================================================

run "basic_environment" {
  command = apply

  assert {
    condition     = github_repository_environment.this.repository == "test-repo"
    error_message = "Repository should match the variable."
  }

  assert {
    condition     = github_repository_environment.this.environment == "test-env"
    error_message = "Environment name should match the variable."
  }

  assert {
    condition     = github_repository_environment.this.can_admins_bypass == true
    error_message = "can_admins_bypass should default to true."
  }

  assert {
    condition     = github_repository_environment.this.prevent_self_review == false
    error_message = "prevent_self_review should default to false."
  }

  assert {
    condition     = length(github_actions_environment_variable.this) == 0
    error_message = "No variables should be created by default."
  }

  assert {
    condition     = length(github_actions_environment_secret.this) == 0
    error_message = "No secrets should be created by default."
  }

  assert {
    condition     = length(github_repository_environment_deployment_policy.this) == 0
    error_message = "No deployment policies should be created by default."
  }
}

# =============================================================================
# Custom environment settings
# =============================================================================

run "custom_environment_settings" {
  command = apply

  variables {
    repository          = "test-repo"
    environment         = "production"
    wait_timer          = 30
    can_admins_bypass   = false
    prevent_self_review = true
  }

  assert {
    condition     = github_repository_environment.this.environment == "production"
    error_message = "Environment name should be 'production'."
  }

  assert {
    condition     = github_repository_environment.this.wait_timer == 30
    error_message = "Wait timer should be 30."
  }

  assert {
    condition     = github_repository_environment.this.can_admins_bypass == false
    error_message = "can_admins_bypass should be false when explicitly set."
  }

  assert {
    condition     = github_repository_environment.this.prevent_self_review == true
    error_message = "prevent_self_review should be true when explicitly set."
  }
}

# =============================================================================
# Environment variables
# =============================================================================

run "environment_variables" {
  command = apply

  variables {
    repository  = "test-repo"
    environment = "staging"
    variables = {
      region = {
        name  = "REGION"
        value = "us-east-1"
      }
      debug = {
        name  = "DEBUG"
        value = "true"
      }
    }
  }

  assert {
    condition     = length(github_actions_environment_variable.this) == 2
    error_message = "Should create 2 environment variables."
  }

  assert {
    condition     = github_actions_environment_variable.this["region"].variable_name == "REGION"
    error_message = "Variable name should be REGION."
  }

  assert {
    condition     = github_actions_environment_variable.this["region"].value == "us-east-1"
    error_message = "Variable value should be us-east-1."
  }

  assert {
    condition     = github_actions_environment_variable.this["debug"].variable_name == "DEBUG"
    error_message = "Variable name should be DEBUG."
  }

  assert {
    condition     = github_actions_environment_variable.this["debug"].value == "true"
    error_message = "Variable value should be true."
  }
}

# =============================================================================
# Environment secrets (names only)
# =============================================================================

run "environment_secrets" {
  command = apply

  variables {
    repository  = "test-repo"
    environment = "staging"
    secrets = {
      api_key     = { name = "API_KEY" }
      db_password = { name = "DB_PASSWORD" }
    }
  }

  assert {
    condition     = length(github_actions_environment_secret.this) == 2
    error_message = "Should create 2 environment secrets."
  }

  assert {
    condition     = output.secrets["api_key"].secret_name == "API_KEY"
    error_message = "Secret name should be API_KEY."
  }

  assert {
    condition     = output.secrets["db_password"].secret_name == "DB_PASSWORD"
    error_message = "Secret name should be DB_PASSWORD."
  }
}

# =============================================================================
# Custom deployment policies (branches and tags)
# =============================================================================

run "custom_branch_deployment_policies" {
  command = apply

  variables {
    repository  = "test-repo"
    environment = "production"
    deployment_policy = {
      custom_branch_policies = true
    }
    branch_policies = ["releases/*", "main"]
  }

  assert {
    condition     = length(github_repository_environment_deployment_policy.this) == 2
    error_message = "Should create 2 branch deployment policies."
  }

  assert {
    condition     = github_repository_environment_deployment_policy.this["branch:releases/*"].branch_pattern == "releases/*"
    error_message = "Branch pattern should be releases/*."
  }

  assert {
    condition     = github_repository_environment_deployment_policy.this["branch:main"].branch_pattern == "main"
    error_message = "Branch pattern should be main."
  }
}

run "custom_tag_deployment_policies" {
  command = apply

  variables {
    repository  = "test-repo"
    environment = "production"
    deployment_policy = {
      custom_branch_policies = true
    }
    tag_policies = ["v*"]
  }

  assert {
    condition     = length(github_repository_environment_deployment_policy.this) == 1
    error_message = "Should create 1 tag deployment policy."
  }

  assert {
    condition     = github_repository_environment_deployment_policy.this["tag:v*"].tag_pattern == "v*"
    error_message = "Tag pattern should be v*."
  }
}

run "mixed_branch_and_tag_policies" {
  command = apply

  variables {
    repository  = "test-repo"
    environment = "production"
    deployment_policy = {
      custom_branch_policies = true
    }
    branch_policies = ["releases/*", "main"]
    tag_policies    = ["v*"]
  }

  assert {
    condition     = length(github_repository_environment_deployment_policy.this) == 3
    error_message = "Should create 3 deployment policies (2 branch + 1 tag)."
  }
}

run "protected_branches_deployment_policy" {
  command = apply

  variables {
    repository  = "test-repo"
    environment = "production"
    deployment_policy = {
      protected_branches = true
    }
  }

  assert {
    condition     = length(github_repository_environment_deployment_policy.this) == 0
    error_message = "No custom deployment policies should be created with protected_branches only."
  }
}

# =============================================================================
# Outputs
# =============================================================================

run "outputs_populated" {
  command = apply

  variables {
    repository  = "test-repo"
    environment = "staging"
    variables = {
      region = {
        name  = "REGION"
        value = "us-east-1"
      }
    }
    secrets = {
      api_key = { name = "API_KEY" }
    }
    deployment_policy = {
      custom_branch_policies = true
    }
    branch_policies = ["main"]
  }

  assert {
    condition     = output.environment.environment == "staging"
    error_message = "Environment output should expose the environment resource."
  }

  assert {
    condition     = length(output.variables) == 1
    error_message = "Variables output should contain 1 entry."
  }

  assert {
    condition     = length(output.secrets) == 1
    error_message = "Secrets output should contain 1 entry."
  }

  assert {
    condition     = length(output.deployment_policies) == 1
    error_message = "Deployment policies output should contain 1 entry."
  }
}

# =============================================================================
# Validation
# =============================================================================

run "branch_policies_without_custom_rejected" {
  command = plan

  variables {
    repository      = "test-repo"
    environment     = "bad-env"
    branch_policies = ["main"]
  }

  expect_failures = [
    var.branch_policies,
  ]
}

run "tag_policies_without_custom_rejected" {
  command = plan

  variables {
    repository   = "test-repo"
    environment  = "bad-env"
    tag_policies = ["v*"]
  }

  expect_failures = [
    var.tag_policies,
  ]
}

# =============================================================================
# Azure identity — not created by default
# =============================================================================

run "identity_not_created_by_default" {
  command = apply

  assert {
    condition     = length(azapi_resource.identity) == 0
    error_message = "No identity should be created when identity variable is null."
  }

  assert {
    condition     = length(azapi_resource.federated_identity_credential) == 0
    error_message = "No federated credential should be created when identity variable is null."
  }

  assert {
    condition     = output.identity == null
    error_message = "Identity output should be null when identity is not configured."
  }
}

# =============================================================================
# Azure identity — default OIDC subject (use_default = true)
# =============================================================================

run "identity_with_default_subject" {
  command = apply

  variables {
    repository  = "test-repo"
    environment = "production"
    identity = {
      name      = "id-test-repo-production"
      parent_id = "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/rg-identities"
      location  = "uksouth"
    }
    actions_oidc_subject_claims = null
    repository_full_name        = "test-org/test-repo"
  }

  assert {
    condition     = length(azapi_resource.identity) == 1
    error_message = "Should create one managed identity."
  }

  assert {
    condition     = azapi_resource.identity[0].name == "id-test-repo-production"
    error_message = "Identity name should match."
  }

  assert {
    condition     = azapi_resource.identity[0].location == "uksouth"
    error_message = "Identity location should be uksouth."
  }

  assert {
    condition     = azapi_resource.identity[0].parent_id == "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/rg-identities"
    error_message = "Identity parent_id should match the resource group."
  }

  assert {
    condition     = length(azapi_resource.federated_identity_credential) == 1
    error_message = "Should create one federated identity credential."
  }

  assert {
    condition     = azapi_resource.federated_identity_credential[0].name == "production"
    error_message = "Federated credential name should be the environment name."
  }

  assert {
    condition     = local.federated_subject == "repo:test-org/test-repo:environment:production"
    error_message = "Subject should use the default GitHub OIDC format."
  }

  assert {
    condition     = output.identity != null
    error_message = "Identity output should not be null when identity is configured."
  }
}

# =============================================================================
# Azure identity — default OIDC subject (use_default = true, explicit)
# =============================================================================

run "identity_with_use_default_true" {
  command = apply

  variables {
    repository  = "test-repo"
    environment = "staging"
    identity = {
      name      = "id-test-repo-staging"
      parent_id = "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/rg-identities"
      location  = "uksouth"
    }
    actions_oidc_subject_claims = {
      use_default        = true
      include_claim_keys = []
    }
    repository_full_name = "test-org/test-repo"
  }

  assert {
    condition     = local.federated_subject == "repo:test-org/test-repo:environment:staging"
    error_message = "Subject should use the default GitHub OIDC format when use_default is true."
  }
}

# =============================================================================
# Azure identity — custom OIDC subject claims
# =============================================================================

run "identity_with_custom_subject_claims" {
  command = apply

  variables {
    repository  = "test-repo"
    environment = "production"
    identity = {
      name      = "id-test-repo-production"
      parent_id = "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/rg-identities"
      location  = "uksouth"
    }
    actions_oidc_subject_claims = {
      use_default = false
      include_claim_keys = [
        "repository_owner_id",
        "repository_id",
        "environment",
      ]
    }
    oidc_subject_claim_values = {
      repository_owner_id = "6844498"
      repository_id       = "760046975"
    }
    repository_full_name = "test-org/test-repo"
  }

  assert {
    condition     = local.federated_subject == "repository_owner_id:6844498:repository_id:760046975:environment:production"
    error_message = "Subject should use key:value format with custom claims."
  }
}

# =============================================================================
# Azure identity — custom claims with user-supplied values (e.g. job_workflow_ref)
# =============================================================================

run "identity_with_user_supplied_claim_values" {
  command = apply

  variables {
    repository  = "test-repo"
    environment = "production"
    identity = {
      name      = "id-test-repo-production"
      parent_id = "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/rg-identities"
      location  = "uksouth"
    }
    actions_oidc_subject_claims = {
      use_default = false
      include_claim_keys = [
        "repository_owner_id",
        "repository_id",
        "job_workflow_ref",
        "environment",
      ]
    }
    oidc_subject_claim_values = {
      repository_owner_id = "6844498"
      repository_id       = "760046975"
      job_workflow_ref    = "my-org/shared-workflows/.github/workflows/deploy.yml@refs/heads/main"
    }
    repository_full_name = "test-org/test-repo"
  }

  assert {
    condition     = local.federated_subject == "repository_owner_id:6844498:repository_id:760046975:job_workflow_ref:my-org/shared-workflows/.github/workflows/deploy.yml@refs/heads/main:environment:production"
    error_message = "Subject should include user-supplied claim values in key:value format."
  }
}

# =============================================================================
# Azure identity — explicit subject override
# =============================================================================

run "identity_with_explicit_subject_override" {
  command = apply

  variables {
    repository  = "test-repo"
    environment = "production"
    identity = {
      name      = "id-test-repo-production"
      parent_id = "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/rg-identities"
      location  = "uksouth"
      subject   = "repo:my-org/my-repo:environment:production"
    }
    actions_oidc_subject_claims = {
      use_default = false
      include_claim_keys = [
        "repository_owner_id",
        "repository_id",
        "environment",
      ]
    }
    oidc_subject_claim_values = {
      repository_owner_id = "6844498"
      repository_id       = "760046975"
    }
    repository_full_name = "test-org/test-repo"
  }

  assert {
    condition     = local.federated_subject == "repo:my-org/my-repo:environment:production"
    error_message = "Subject should use the explicit override when provided."
  }
}

# =============================================================================
# Azure identity — custom audiences
# =============================================================================

run "identity_with_custom_audiences" {
  command = apply

  variables {
    repository  = "test-repo"
    environment = "production"
    identity = {
      name      = "id-test-repo-production"
      parent_id = "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/rg-identities"
      location  = "uksouth"
      audiences = ["https://custom-audience.example.com"]
    }
    actions_oidc_subject_claims = null
    repository_full_name        = "test-org/test-repo"
  }

  assert {
    condition     = length(azapi_resource.federated_identity_credential) == 1
    error_message = "Should create one federated identity credential."
  }
}

# =============================================================================
# Azure role assignments — not created by default
# =============================================================================

run "role_assignments_not_created_by_default" {
  command = apply

  assert {
    condition     = length(azapi_resource.role_assignment) == 0
    error_message = "No role assignments should be created when role_assignments is empty."
  }

  assert {
    condition     = length(output.role_assignments) == 0
    error_message = "Role assignments output should be empty by default."
  }
}

# =============================================================================
# Azure role assignments — single assignment
# =============================================================================

run "single_role_assignment" {
  command = apply

  variables {
    repository  = "test-repo"
    environment = "production"
    identity = {
      name      = "id-test-repo-production"
      parent_id = "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/rg-identities"
      location  = "uksouth"
    }
    actions_oidc_subject_claims = null
    repository_full_name        = "test-org/test-repo"
    role_assignments = {
      reader = {
        role_definition_id = "/subscriptions/00000000-0000-0000-0000-000000000000/providers/Microsoft.Authorization/roleDefinitions/acdd72a7-3385-48ef-bd42-f606fba81ae7"
        scope              = "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/rg-app"
      }
    }
  }

  assert {
    condition     = length(azapi_resource.role_assignment) == 1
    error_message = "Should create one role assignment."
  }

  assert {
    condition     = length(random_uuid.role_assignment) == 1
    error_message = "Should create one random UUID for the role assignment name."
  }

  assert {
    condition     = azapi_resource.role_assignment["reader"].parent_id == "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/rg-app"
    error_message = "Role assignment parent_id should be the scope."
  }

  assert {
    condition     = length(output.role_assignments) == 1
    error_message = "Role assignments output should contain 1 entry."
  }

  assert {
    condition     = output.role_assignments["reader"].role_definition_id == "/subscriptions/00000000-0000-0000-0000-000000000000/providers/Microsoft.Authorization/roleDefinitions/acdd72a7-3385-48ef-bd42-f606fba81ae7"
    error_message = "Role assignment output should expose role_definition_id."
  }

  assert {
    condition     = output.role_assignments["reader"].scope == "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/rg-app"
    error_message = "Role assignment output should expose scope."
  }
}

# =============================================================================
# Azure role assignments — multiple assignments
# =============================================================================

run "multiple_role_assignments" {
  command = apply

  variables {
    repository  = "test-repo"
    environment = "production"
    identity = {
      name      = "id-test-repo-production"
      parent_id = "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/rg-identities"
      location  = "uksouth"
    }
    actions_oidc_subject_claims = null
    repository_full_name        = "test-org/test-repo"
    role_assignments = {
      reader = {
        role_definition_id = "/subscriptions/00000000-0000-0000-0000-000000000000/providers/Microsoft.Authorization/roleDefinitions/acdd72a7-3385-48ef-bd42-f606fba81ae7"
        scope              = "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/rg-app"
      }
      contributor = {
        role_definition_id = "/subscriptions/00000000-0000-0000-0000-000000000000/providers/Microsoft.Authorization/roleDefinitions/b24988ac-6180-42a0-ab88-20f7382dd24c"
        scope              = "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/rg-data"
      }
    }
  }

  assert {
    condition     = length(azapi_resource.role_assignment) == 2
    error_message = "Should create two role assignments."
  }

  assert {
    condition     = length(random_uuid.role_assignment) == 2
    error_message = "Should create two random UUIDs for the role assignment names."
  }

  assert {
    condition     = length(output.role_assignments) == 2
    error_message = "Role assignments output should contain 2 entries."
  }
}

# =============================================================================
# Azure role assignments — with condition
# =============================================================================

run "role_assignment_with_condition" {
  command = apply

  variables {
    repository  = "test-repo"
    environment = "production"
    identity = {
      name      = "id-test-repo-production"
      parent_id = "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/rg-identities"
      location  = "uksouth"
    }
    actions_oidc_subject_claims = null
    repository_full_name        = "test-org/test-repo"
    role_assignments = {
      storage_blob_reader = {
        role_definition_id = "/subscriptions/00000000-0000-0000-0000-000000000000/providers/Microsoft.Authorization/roleDefinitions/2a2b9908-6ea1-4ae2-8e65-a410df84e7d1"
        scope              = "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/rg-storage"
        condition          = "@Resource[Microsoft.Storage/storageAccounts/blobServices/containers:name] StringEquals 'my-container'"
        condition_version  = "2.0"
      }
    }
  }

  assert {
    condition     = length(azapi_resource.role_assignment) == 1
    error_message = "Should create one role assignment with condition."
  }

  assert {
    condition     = length(output.role_assignments) == 1
    error_message = "Role assignments output should contain 1 entry."
  }
}

# =============================================================================
# Azure role assignments — validation: requires identity
# =============================================================================

run "role_assignments_without_identity_rejected" {
  command = plan

  variables {
    repository  = "test-repo"
    environment = "bad-env"
    role_assignments = {
      reader = {
        role_definition_id = "/subscriptions/00000000-0000-0000-0000-000000000000/providers/Microsoft.Authorization/roleDefinitions/acdd72a7-3385-48ef-bd42-f606fba81ae7"
        scope              = "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/rg-app"
      }
    }
  }

  expect_failures = [
    var.role_assignments,
  ]
}
