variable "repository" {
  description = <<DESCRIPTION
The name of the repository.
DESCRIPTION
  type        = string
  nullable    = false
}

variable "name" {
  description = <<DESCRIPTION
The name of the ruleset.
DESCRIPTION
  type        = string
  nullable    = false
}

variable "enforcement" {
  description = <<DESCRIPTION
The enforcement level: `disabled`, `active`, or `evaluate`.
DESCRIPTION
  type        = string
  nullable    = false

  validation {
    condition     = contains(["disabled", "active", "evaluate"], var.enforcement)
    error_message = "enforcement must be one of: disabled, active, evaluate."
  }
}

variable "target" {
  description = <<DESCRIPTION
The target of the ruleset: `branch`, `tag`, or `push`.
DESCRIPTION
  type        = string
  default     = "branch"
  nullable    = false

  validation {
    condition     = contains(["branch", "tag", "push"], var.target)
    error_message = "target must be one of: branch, tag, push."
  }
}

variable "bypass_actors" {
  description = <<DESCRIPTION
List of actors that can bypass the ruleset.

- `actor_id` - The ID of the actor (set to `1` for `OrganizationAdmin`; omit for `DeployKey`).
- `actor_type` - The type of actor: `Integration`, `OrganizationAdmin`, `RepositoryRole`, `Team`, `DeployKey`.
- `bypass_mode` - The bypass mode: `always`, `pull_request`.
DESCRIPTION
  type = list(object({
    actor_id    = optional(number)
    actor_type  = string
    bypass_mode = string
  }))
  default  = []
  nullable = false
}

variable "conditions" {
  description = <<DESCRIPTION
Conditions for the ruleset, containing a ref_name block.

- `ref_name` - Target branches or tags:
  - `include` - List of ref patterns to include.
  - `exclude` - List of ref patterns to exclude.
DESCRIPTION
  type = object({
    ref_name = object({
      include = list(string)
      exclude = list(string)
    })
  })
  nullable = false
}

variable "rules" {
  description = <<DESCRIPTION
Rules enforced by the ruleset.

Simple rules (set to `true` to enable):
- `creation` - Only allow bypass actors to create matching refs.
- `deletion` - Only allow bypass actors to delete matching refs.
- `update` - Only allow bypass actors to update matching refs.
- `non_fast_forward` - Prevent force pushes to matching refs.
- `required_linear_history` - Prevent merge commits from being pushed to matching refs.
- `required_signatures` - Require commits to be signed.
- `update_allows_fetch_and_merge` - Allow forked repos to pull changes from upstream. Requires `update` to be `true`.

Complex rules:
- `pull_request` - Require pull requests before merging:
  - `dismiss_stale_reviews_on_push` - Dismiss approvals when new commits are pushed.
  - `require_code_owner_review` - Require review from code owners.
  - `require_last_push_approval` - Require approval from someone other than the last pusher.
  - `required_approving_review_count` - Number of required approving reviews (0-10).
  - `required_review_thread_resolution` - All review threads must be resolved.
  - `allowed_merge_methods` - Allowed merge methods (e.g. `merge`, `squash`, `rebase`).
- `required_status_checks` - Require status checks to pass:
  - `strict_required_status_checks_policy` - Require branches to be up to date before merging.
  - `do_not_enforce_on_create` - Do not enforce on ref creation.
  - `required_check` - List of required status checks:
    - `context` - The status check context name.
    - `integration_id` - The integration ID for the status check.
- `required_deployments` - Require deployments to succeed:
  - `required_deployment_environments` - List of required deployment environment names.
- `required_code_scanning` - Require code scanning results:
  - `required_code_scanning_tool` - List of required code scanning tools:
    - `tool` - The name of the tool.
    - `alerts_threshold` - Alert threshold (e.g. `errors`, `all`, `none`).
    - `security_alerts_threshold` - Security alert threshold (e.g. `critical`, `high_or_higher`, `medium_or_higher`, `all`, `none`).
- `merge_queue` - Merge queue settings:
  - `check_response_timeout_minutes` - Timeout for status check responses.
  - `grouping_strategy` - Grouping strategy: `NONE` or `ALLGREEN`.
  - `max_entries_to_build` - Max entries to build concurrently.
  - `max_entries_to_merge` - Max entries to merge in a single group.
  - `merge_method` - Merge method: `MERGE`, `SQUASH`, or `REBASE`.
  - `min_entries_to_merge` - Min entries to merge in a single group.
  - `min_entries_to_merge_wait_minutes` - Min wait time before merging.
- `copilot_code_review` - Copilot code review settings:
  - `review_draft_pull_requests` - Review draft pull requests.
  - `review_on_push` - Review on push events.

Pattern rules:
- `branch_name_pattern` - Branch name pattern restriction.
- `tag_name_pattern` - Tag name pattern restriction.
- `commit_author_email_pattern` - Commit author email pattern restriction.
- `commit_message_pattern` - Commit message pattern restriction.
- `committer_email_pattern` - Committer email pattern restriction.
  Each pattern rule has: `operator` (e.g. `starts_with`, `ends_with`, `contains`, `regex`),
  `pattern`, optional `name`, and optional `negate`.

File rules:
- `file_extension_restriction` - Restrict file extensions:
  - `restricted_file_extensions` - Set of restricted file extensions.
- `file_path_restriction` - Restrict file paths:
  - `restricted_file_paths` - List of restricted file paths.
- `max_file_path_length` - Maximum file path length:
  - `max_file_path_length` - The maximum file path length.
- `max_file_size` - Maximum file size:
  - `max_file_size` - The maximum file size in MB (1-100).
DESCRIPTION
  type = object({
    # Simple boolean rules
    creation                      = optional(bool)
    deletion                      = optional(bool)
    update                        = optional(bool)
    non_fast_forward              = optional(bool)
    required_linear_history       = optional(bool)
    required_signatures           = optional(bool)
    update_allows_fetch_and_merge = optional(bool)

    # Pull request
    pull_request = optional(object({
      dismiss_stale_reviews_on_push     = optional(bool, false)
      require_code_owner_review         = optional(bool, false)
      require_last_push_approval        = optional(bool, false)
      required_approving_review_count   = optional(number, 0)
      required_review_thread_resolution = optional(bool, false)
      allowed_merge_methods             = optional(set(string), [])
    }))

    # Required status checks
    required_status_checks = optional(object({
      strict_required_status_checks_policy = optional(bool, false)
      do_not_enforce_on_create             = optional(bool, false)
      required_check = list(object({
        context        = string
        integration_id = optional(number)
      }))
    }))

    # Required deployments
    required_deployments = optional(object({
      required_deployment_environments = list(string)
    }))

    # Required code scanning
    required_code_scanning = optional(object({
      required_code_scanning_tool = list(object({
        tool                      = string
        alerts_threshold          = string
        security_alerts_threshold = string
      }))
    }))

    # Merge queue
    merge_queue = optional(object({
      check_response_timeout_minutes    = optional(number, 5)
      grouping_strategy                 = optional(string, "NONE")
      max_entries_to_build              = optional(number, 5)
      max_entries_to_merge              = optional(number, 5)
      merge_method                      = optional(string, "MERGE")
      min_entries_to_merge              = optional(number, 1)
      min_entries_to_merge_wait_minutes = optional(number, 5)
    }))

    # Copilot code review
    copilot_code_review = optional(object({
      review_draft_pull_requests = optional(bool, false)
      review_on_push             = optional(bool, false)
    }))

    # Pattern rules
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

    # File restrictions
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
  nullable = false

  validation {
    condition     = var.rules.update_allows_fetch_and_merge == null || var.rules.update_allows_fetch_and_merge == false || var.rules.update == true
    error_message = "update_allows_fetch_and_merge requires update to be true."
  }
}
