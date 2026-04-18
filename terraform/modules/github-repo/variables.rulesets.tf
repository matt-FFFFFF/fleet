variable "rulesets" {
  description = <<DESCRIPTION
Map of repository rulesets to create.
The map key is an arbitrary identifier to avoid known-after-apply issues.

- `name` - The name of the ruleset.
- `enforcement` - The enforcement level: `disabled`, `active`, or `evaluate`.
- `target` - The target of the ruleset: `branch`, `tag`, or `push`. Defaults to `branch`.
- `bypass_actors` - List of actors that can bypass the ruleset:
  - `actor_id` - The ID of the actor.
  - `actor_type` - The type: `Integration`, `OrganizationAdmin`, `RepositoryRole`, `Team`, `DeployKey`.
  - `bypass_mode` - The bypass mode: `always`, `pull_request`.
- `conditions` - Conditions for the ruleset:
  - `ref_name` - Target refs:
    - `include` - List of ref patterns to include.
    - `exclude` - List of ref patterns to exclude.
- `rules` - The rules enforced by the ruleset. See the submodule documentation for all available rules.
DESCRIPTION
  type = map(object({
    name        = string
    enforcement = string
    target      = optional(string, "branch")
    bypass_actors = optional(list(object({
      actor_id    = optional(number)
      actor_type  = string
      bypass_mode = string
    })), [])
    conditions = object({
      ref_name = object({
        include = list(string)
        exclude = list(string)
      })
    })
    rules = object({
      creation                      = optional(bool)
      deletion                      = optional(bool)
      update                        = optional(bool)
      non_fast_forward              = optional(bool)
      required_linear_history       = optional(bool)
      required_signatures           = optional(bool)
      update_allows_fetch_and_merge = optional(bool)

      pull_request = optional(object({
        dismiss_stale_reviews_on_push     = optional(bool, false)
        require_code_owner_review         = optional(bool, false)
        require_last_push_approval        = optional(bool, false)
        required_approving_review_count   = optional(number, 0)
        required_review_thread_resolution = optional(bool, false)
        allowed_merge_methods             = optional(set(string), [])
      }))

      required_status_checks = optional(object({
        strict_required_status_checks_policy = optional(bool, false)
        do_not_enforce_on_create             = optional(bool, false)
        required_check = list(object({
          context        = string
          integration_id = optional(number)
        }))
      }))

      required_deployments = optional(object({
        required_deployment_environments = list(string)
      }))

      required_code_scanning = optional(object({
        required_code_scanning_tool = list(object({
          tool                      = string
          alerts_threshold          = string
          security_alerts_threshold = string
        }))
      }))

      merge_queue = optional(object({
        check_response_timeout_minutes    = optional(number, 5)
        grouping_strategy                 = optional(string, "NONE")
        max_entries_to_build              = optional(number, 5)
        max_entries_to_merge              = optional(number, 5)
        merge_method                      = optional(string, "MERGE")
        min_entries_to_merge              = optional(number, 1)
        min_entries_to_merge_wait_minutes = optional(number, 5)
      }))

      copilot_code_review = optional(object({
        review_draft_pull_requests = optional(bool, false)
        review_on_push             = optional(bool, false)
      }))

      branch_name_pattern = optional(object({
        operator = string
        pattern  = string
        name     = optional(string)
        negate   = optional(bool, false)
      }))

      tag_name_pattern = optional(object({
        operator = string
        pattern  = string
        name     = optional(string)
        negate   = optional(bool, false)
      }))

      commit_author_email_pattern = optional(object({
        operator = string
        pattern  = string
        name     = optional(string)
        negate   = optional(bool, false)
      }))

      commit_message_pattern = optional(object({
        operator = string
        pattern  = string
        name     = optional(string)
        negate   = optional(bool, false)
      }))

      committer_email_pattern = optional(object({
        operator = string
        pattern  = string
        name     = optional(string)
        negate   = optional(bool, false)
      }))

      file_extension_restriction = optional(object({
        restricted_file_extensions = set(string)
      }))

      file_path_restriction = optional(object({
        restricted_file_paths = list(string)
      }))

      max_file_path_length = optional(object({
        max_file_path_length = number
      }))

      max_file_size = optional(object({
        max_file_size = number
      }))
    })
  }))
  default  = {}
  nullable = false

  validation {
    condition = alltrue([
      for k, v in var.rulesets :
      contains(["disabled", "active", "evaluate"], v.enforcement)
    ])
    error_message = "enforcement must be one of: disabled, active, evaluate."
  }

  validation {
    condition = alltrue([
      for k, v in var.rulesets :
      contains(["branch", "tag", "push"], v.target)
    ])
    error_message = "target must be one of: branch, tag, push."
  }
}
