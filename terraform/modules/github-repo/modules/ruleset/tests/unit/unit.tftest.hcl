# -----------------------------------------------------------------------------
# Unit tests for modules/ruleset
#
# These tests use provider mocking so no real GitHub resources are created.
# -----------------------------------------------------------------------------

mock_provider "github" {
  mock_resource "github_repository_ruleset" {
    defaults = {
      node_id    = "RSL_abc123"
      ruleset_id = 12345
      etag       = "etag-123"
    }
  }
}

# File-level variables applied to all run blocks unless overridden.
variables {
  repository  = "test-repo"
  name        = "test-ruleset"
  enforcement = "active"
  conditions = {
    ref_name = {
      include = ["~DEFAULT_BRANCH"]
      exclude = []
    }
  }
  rules = {}
}

# =============================================================================
# Basic branch ruleset
# =============================================================================

run "basic_branch_ruleset" {
  command = apply

  assert {
    condition     = github_repository_ruleset.this.repository == "test-repo"
    error_message = "Repository should match the variable."
  }

  assert {
    condition     = github_repository_ruleset.this.name == "test-ruleset"
    error_message = "Name should match the variable."
  }

  assert {
    condition     = github_repository_ruleset.this.enforcement == "active"
    error_message = "Enforcement should match the variable."
  }

  assert {
    condition     = github_repository_ruleset.this.target == "branch"
    error_message = "Target should default to branch."
  }

  assert {
    condition     = output.ruleset.name == "test-ruleset"
    error_message = "Output ruleset name should match the variable."
  }
}

# =============================================================================
# Tag target ruleset
# =============================================================================

run "tag_target_ruleset" {
  command = apply

  variables {
    target = "tag"
    rules = {
      deletion         = true
      non_fast_forward = true
    }
  }

  assert {
    condition     = github_repository_ruleset.this.target == "tag"
    error_message = "Target should be tag."
  }
}

# =============================================================================
# Push target ruleset
# =============================================================================

run "push_target_ruleset" {
  command = apply

  variables {
    target = "push"
    rules  = {}
  }

  assert {
    condition     = github_repository_ruleset.this.target == "push"
    error_message = "Target should be push."
  }
}

# =============================================================================
# Pull request rules
# =============================================================================

run "pull_request_rules" {
  command = apply

  variables {
    rules = {
      pull_request = {
        dismiss_stale_reviews_on_push     = true
        require_code_owner_review         = true
        require_last_push_approval        = true
        required_approving_review_count   = 2
        required_review_thread_resolution = true
        allowed_merge_methods             = ["squash", "rebase"]
      }
    }
  }

  assert {
    condition     = github_repository_ruleset.this.rules[0].pull_request[0].required_approving_review_count == 2
    error_message = "Required approving review count should be 2."
  }

  assert {
    condition     = github_repository_ruleset.this.rules[0].pull_request[0].dismiss_stale_reviews_on_push == true
    error_message = "Dismiss stale reviews on push should be true."
  }

  assert {
    condition     = github_repository_ruleset.this.rules[0].pull_request[0].require_code_owner_review == true
    error_message = "Require code owner review should be true."
  }
}

# =============================================================================
# Required status checks rules
# =============================================================================

run "required_status_checks_rules" {
  command = apply

  variables {
    rules = {
      required_status_checks = {
        strict_required_status_checks_policy = true
        required_check = [
          { context = "ci/build" },
          { context = "ci/test", integration_id = 1234 },
        ]
      }
    }
  }

  assert {
    condition     = github_repository_ruleset.this.rules[0].required_status_checks[0].strict_required_status_checks_policy == true
    error_message = "Strict required status checks policy should be true."
  }

  assert {
    condition     = length(github_repository_ruleset.this.rules[0].required_status_checks[0].required_check) == 2
    error_message = "Should have 2 required checks."
  }
}

# =============================================================================
# Required deployments rules
# =============================================================================

run "required_deployments_rules" {
  command = apply

  variables {
    rules = {
      required_deployments = {
        required_deployment_environments = ["staging", "production"]
      }
    }
  }

  assert {
    condition     = length(github_repository_ruleset.this.rules[0].required_deployments[0].required_deployment_environments) == 2
    error_message = "Should have 2 required deployment environments."
  }
}

# =============================================================================
# Required code scanning rules
# =============================================================================

run "required_code_scanning_rules" {
  command = apply

  variables {
    rules = {
      required_code_scanning = {
        required_code_scanning_tool = [
          {
            tool                      = "CodeQL"
            alerts_threshold          = "errors"
            security_alerts_threshold = "high_or_higher"
          }
        ]
      }
    }
  }

  assert {
    condition     = length(github_repository_ruleset.this.rules[0].required_code_scanning[0].required_code_scanning_tool) == 1
    error_message = "Should have 1 required code scanning tool."
  }
}

# =============================================================================
# Merge queue rules
# =============================================================================

run "merge_queue_rules" {
  command = apply

  variables {
    rules = {
      merge_queue = {
        check_response_timeout_minutes    = 10
        grouping_strategy                 = "ALLGREEN"
        max_entries_to_build              = 3
        max_entries_to_merge              = 3
        merge_method                      = "SQUASH"
        min_entries_to_merge              = 2
        min_entries_to_merge_wait_minutes = 10
      }
    }
  }

  assert {
    condition     = github_repository_ruleset.this.rules[0].merge_queue[0].merge_method == "SQUASH"
    error_message = "Merge method should be SQUASH."
  }

  assert {
    condition     = github_repository_ruleset.this.rules[0].merge_queue[0].grouping_strategy == "ALLGREEN"
    error_message = "Grouping strategy should be ALLGREEN."
  }
}

# =============================================================================
# Copilot code review rules
# =============================================================================

run "copilot_code_review_rules" {
  command = apply

  variables {
    rules = {
      copilot_code_review = {
        review_draft_pull_requests = true
        review_on_push             = true
      }
    }
  }

  assert {
    condition     = github_repository_ruleset.this.rules[0].copilot_code_review[0].review_draft_pull_requests == true
    error_message = "Review draft pull requests should be true."
  }

  assert {
    condition     = github_repository_ruleset.this.rules[0].copilot_code_review[0].review_on_push == true
    error_message = "Review on push should be true."
  }
}

# =============================================================================
# Pattern rules
# =============================================================================

run "pattern_rules" {
  command = apply

  variables {
    rules = {
      branch_name_pattern = {
        operator = "regex"
        pattern  = "^(main|release/.*)$"
        name     = "branch-naming-convention"
      }
      commit_message_pattern = {
        operator = "starts_with"
        pattern  = "feat:|fix:|docs:|chore:"
        name     = "conventional-commits"
        negate   = true
      }
    }
  }

  assert {
    condition     = github_repository_ruleset.this.rules[0].branch_name_pattern[0].operator == "regex"
    error_message = "Branch name pattern operator should be regex."
  }

  assert {
    condition     = github_repository_ruleset.this.rules[0].branch_name_pattern[0].pattern == "^(main|release/.*)$"
    error_message = "Branch name pattern should match."
  }

  assert {
    condition     = github_repository_ruleset.this.rules[0].commit_message_pattern[0].operator == "starts_with"
    error_message = "Commit message pattern operator should be starts_with."
  }
}

# =============================================================================
# File restriction rules
# =============================================================================

run "file_restriction_rules" {
  command = apply

  variables {
    rules = {
      file_extension_restriction = {
        restricted_file_extensions = [".exe", ".dll"]
      }
      file_path_restriction = {
        restricted_file_paths = ["secrets/", ".env"]
      }
      max_file_path_length = {
        max_file_path_length = 255
      }
      max_file_size = {
        max_file_size = 10
      }
    }
  }

  assert {
    condition     = length(github_repository_ruleset.this.rules[0].file_extension_restriction[0].restricted_file_extensions) == 2
    error_message = "Should have 2 restricted file extensions."
  }

  assert {
    condition     = length(github_repository_ruleset.this.rules[0].file_path_restriction[0].restricted_file_paths) == 2
    error_message = "Should have 2 restricted file paths."
  }

  assert {
    condition     = github_repository_ruleset.this.rules[0].max_file_path_length[0].max_file_path_length == 255
    error_message = "Max file path length should be 255."
  }

  assert {
    condition     = github_repository_ruleset.this.rules[0].max_file_size[0].max_file_size == 10
    error_message = "Max file size should be 10."
  }
}

# =============================================================================
# Bypass actors configured
# =============================================================================

run "bypass_actors_configured" {
  command = apply

  variables {
    bypass_actors = [
      {
        actor_id    = 1
        actor_type  = "OrganizationAdmin"
        bypass_mode = "always"
      },
      {
        actor_id    = 123
        actor_type  = "Team"
        bypass_mode = "pull_request"
      },
    ]
  }

  assert {
    condition     = length(github_repository_ruleset.this.bypass_actors) == 2
    error_message = "Should have 2 bypass actors."
  }
}

# =============================================================================
# Multiple rules combined
# =============================================================================

run "multiple_rules_combined" {
  command = apply

  variables {
    rules = {
      creation         = true
      deletion         = true
      non_fast_forward = true
      pull_request = {
        required_approving_review_count = 1
        require_code_owner_review       = true
        allowed_merge_methods           = ["squash"]
      }
      required_status_checks = {
        required_check = [
          { context = "ci/build" },
        ]
      }
    }
  }

  assert {
    condition     = github_repository_ruleset.this.rules[0].creation == true
    error_message = "Creation rule should be true."
  }

  assert {
    condition     = github_repository_ruleset.this.rules[0].deletion == true
    error_message = "Deletion rule should be true."
  }

  assert {
    condition     = github_repository_ruleset.this.rules[0].non_fast_forward == true
    error_message = "Non fast forward rule should be true."
  }

  assert {
    condition     = github_repository_ruleset.this.rules[0].pull_request[0].required_approving_review_count == 1
    error_message = "Required approving review count should be 1."
  }
}

# =============================================================================
# Outputs
# =============================================================================

run "outputs_populated" {
  command = apply

  assert {
    condition     = output.ruleset.name == "test-ruleset"
    error_message = "Output ruleset name should match the variable."
  }

  assert {
    condition     = output.ruleset.enforcement == "active"
    error_message = "Output ruleset enforcement should match the variable."
  }

  assert {
    condition     = output.ruleset.target == "branch"
    error_message = "Output ruleset target should default to branch."
  }
}

# =============================================================================
# Disabled enforcement
# =============================================================================

run "disabled_enforcement" {
  command = apply

  variables {
    enforcement = "disabled"
  }

  assert {
    condition     = github_repository_ruleset.this.enforcement == "disabled"
    error_message = "Enforcement should be disabled."
  }
}

# =============================================================================
# Validation
# =============================================================================

run "invalid_enforcement_rejected" {
  command = plan

  variables {
    enforcement = "invalid"
  }

  expect_failures = [
    var.enforcement,
  ]
}

run "invalid_target_rejected" {
  command = plan

  variables {
    target = "invalid"
  }

  expect_failures = [
    var.target,
  ]
}

run "update_allows_fetch_and_merge_without_update_rejected" {
  command = plan

  variables {
    rules = {
      update_allows_fetch_and_merge = true
    }
  }

  expect_failures = [
    var.rules,
  ]
}
