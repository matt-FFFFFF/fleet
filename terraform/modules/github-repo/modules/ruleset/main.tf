# -----------------------------------------------------------------------------
# Repository ruleset
# -----------------------------------------------------------------------------

resource "github_repository_ruleset" "this" {
  repository  = var.repository
  name        = var.name
  enforcement = var.enforcement
  target      = var.target

  # Bypass actors
  dynamic "bypass_actors" {
    for_each = var.bypass_actors
    content {
      actor_id    = bypass_actors.value.actor_id
      actor_type  = bypass_actors.value.actor_type
      bypass_mode = bypass_actors.value.bypass_mode
    }
  }

  # Conditions
  conditions {
    ref_name {
      include = var.conditions.ref_name.include
      exclude = var.conditions.ref_name.exclude
    }
  }

  # Rules
  rules {
    creation                      = var.rules.creation
    deletion                      = var.rules.deletion
    update                        = var.rules.update
    non_fast_forward              = var.rules.non_fast_forward
    required_linear_history       = var.rules.required_linear_history
    required_signatures           = var.rules.required_signatures
    update_allows_fetch_and_merge = var.rules.update_allows_fetch_and_merge

    dynamic "pull_request" {
      for_each = var.rules.pull_request != null ? [var.rules.pull_request] : []
      content {
        dismiss_stale_reviews_on_push     = pull_request.value.dismiss_stale_reviews_on_push
        require_code_owner_review         = pull_request.value.require_code_owner_review
        require_last_push_approval        = pull_request.value.require_last_push_approval
        required_approving_review_count   = pull_request.value.required_approving_review_count
        required_review_thread_resolution = pull_request.value.required_review_thread_resolution
        allowed_merge_methods             = pull_request.value.allowed_merge_methods
      }
    }

    dynamic "required_status_checks" {
      for_each = var.rules.required_status_checks != null ? [var.rules.required_status_checks] : []
      content {
        strict_required_status_checks_policy = required_status_checks.value.strict_required_status_checks_policy
        do_not_enforce_on_create             = required_status_checks.value.do_not_enforce_on_create

        dynamic "required_check" {
          for_each = required_status_checks.value.required_check
          content {
            context        = required_check.value.context
            integration_id = required_check.value.integration_id
          }
        }
      }
    }

    dynamic "required_deployments" {
      for_each = var.rules.required_deployments != null ? [var.rules.required_deployments] : []
      content {
        required_deployment_environments = required_deployments.value.required_deployment_environments
      }
    }

    dynamic "required_code_scanning" {
      for_each = var.rules.required_code_scanning != null ? [var.rules.required_code_scanning] : []
      content {
        dynamic "required_code_scanning_tool" {
          for_each = required_code_scanning.value.required_code_scanning_tool
          content {
            tool                      = required_code_scanning_tool.value.tool
            alerts_threshold          = required_code_scanning_tool.value.alerts_threshold
            security_alerts_threshold = required_code_scanning_tool.value.security_alerts_threshold
          }
        }
      }
    }

    dynamic "merge_queue" {
      for_each = var.rules.merge_queue != null ? [var.rules.merge_queue] : []
      content {
        check_response_timeout_minutes    = merge_queue.value.check_response_timeout_minutes
        grouping_strategy                 = merge_queue.value.grouping_strategy
        max_entries_to_build              = merge_queue.value.max_entries_to_build
        max_entries_to_merge              = merge_queue.value.max_entries_to_merge
        merge_method                      = merge_queue.value.merge_method
        min_entries_to_merge              = merge_queue.value.min_entries_to_merge
        min_entries_to_merge_wait_minutes = merge_queue.value.min_entries_to_merge_wait_minutes
      }
    }

    dynamic "copilot_code_review" {
      for_each = var.rules.copilot_code_review != null ? [var.rules.copilot_code_review] : []
      content {
        review_draft_pull_requests = copilot_code_review.value.review_draft_pull_requests
        review_on_push             = copilot_code_review.value.review_on_push
      }
    }

    dynamic "branch_name_pattern" {
      for_each = var.rules.branch_name_pattern != null ? [var.rules.branch_name_pattern] : []
      content {
        operator = branch_name_pattern.value.operator
        pattern  = branch_name_pattern.value.pattern
        name     = branch_name_pattern.value.name
        negate   = branch_name_pattern.value.negate
      }
    }

    dynamic "tag_name_pattern" {
      for_each = var.rules.tag_name_pattern != null ? [var.rules.tag_name_pattern] : []
      content {
        operator = tag_name_pattern.value.operator
        pattern  = tag_name_pattern.value.pattern
        name     = tag_name_pattern.value.name
        negate   = tag_name_pattern.value.negate
      }
    }

    dynamic "commit_author_email_pattern" {
      for_each = var.rules.commit_author_email_pattern != null ? [var.rules.commit_author_email_pattern] : []
      content {
        operator = commit_author_email_pattern.value.operator
        pattern  = commit_author_email_pattern.value.pattern
        name     = commit_author_email_pattern.value.name
        negate   = commit_author_email_pattern.value.negate
      }
    }

    dynamic "commit_message_pattern" {
      for_each = var.rules.commit_message_pattern != null ? [var.rules.commit_message_pattern] : []
      content {
        operator = commit_message_pattern.value.operator
        pattern  = commit_message_pattern.value.pattern
        name     = commit_message_pattern.value.name
        negate   = commit_message_pattern.value.negate
      }
    }

    dynamic "committer_email_pattern" {
      for_each = var.rules.committer_email_pattern != null ? [var.rules.committer_email_pattern] : []
      content {
        operator = committer_email_pattern.value.operator
        pattern  = committer_email_pattern.value.pattern
        name     = committer_email_pattern.value.name
        negate   = committer_email_pattern.value.negate
      }
    }

    dynamic "file_extension_restriction" {
      for_each = var.rules.file_extension_restriction != null ? [var.rules.file_extension_restriction] : []
      content {
        restricted_file_extensions = file_extension_restriction.value.restricted_file_extensions
      }
    }

    dynamic "file_path_restriction" {
      for_each = var.rules.file_path_restriction != null ? [var.rules.file_path_restriction] : []
      content {
        restricted_file_paths = file_path_restriction.value.restricted_file_paths
      }
    }

    dynamic "max_file_path_length" {
      for_each = var.rules.max_file_path_length != null ? [var.rules.max_file_path_length] : []
      content {
        max_file_path_length = max_file_path_length.value.max_file_path_length
      }
    }

    dynamic "max_file_size" {
      for_each = var.rules.max_file_size != null ? [var.rules.max_file_size] : []
      content {
        max_file_size = max_file_size.value.max_file_size
      }
    }
  }
}
