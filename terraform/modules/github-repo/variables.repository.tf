variable "create_repository" {
  description = <<DESCRIPTION
Whether to create the GitHub repository. Set to false to manage content in an existing repo.
DESCRIPTION
  type        = bool
  default     = true
  nullable    = false
}

variable "name" {
  description = <<DESCRIPTION
The name of the repository.
DESCRIPTION
  type        = string
  nullable    = false
}

variable "description" {
  description = <<DESCRIPTION
A description of the repository.
DESCRIPTION
  type        = string
  default     = null
}

variable "visibility" {
  description = <<DESCRIPTION
Repository visibility: public, private, or internal.
DESCRIPTION
  type        = string
  default     = "private"

  validation {
    condition     = contains(["public", "private", "internal"], var.visibility)
    error_message = "Visibility must be one of: public, private, internal."
  }
}

variable "default_branch" {
  description = <<DESCRIPTION
The name of the default branch.
DESCRIPTION
  type        = string
  default     = "main"
  nullable    = false
}

variable "template" {
  description = <<DESCRIPTION
Template repository to use when creating the repo. Object with owner and repository keys.
DESCRIPTION
  type = object({
    owner      = string
    repository = string
  })
  default = null
}

variable "files" {
  description = <<DESCRIPTION
Map of file paths to file content to commit to the repository.
The map key is the file path within the repo.

Mutually exclusive with `files_dir`.
DESCRIPTION
  type        = map(string)
  default     = {}
  nullable    = false
}

variable "files_dir" {
  description = <<DESCRIPTION
Path to a local directory whose contents will be committed to the repository.
All files are read recursively. Callers should use an absolute path,
e.g. `$${path.module}/content`.

Mutually exclusive with `files`.
DESCRIPTION
  type        = string
  default     = null

  validation {
    condition     = var.files_dir == null || length(var.files) == 0
    error_message = "Cannot set both files and files_dir. Use one or the other."
  }
}

variable "branch" {
  description = <<DESCRIPTION
Branch to commit files to. Defaults to the default branch.
DESCRIPTION
  type        = string
  default     = null
}

variable "commit_author" {
  description = <<DESCRIPTION
The commit author name for file commits.
DESCRIPTION
  type        = string
  default     = "Terraform"
}

variable "commit_email" {
  description = <<DESCRIPTION
The commit author email for file commits.
DESCRIPTION
  type        = string
  default     = "terraform@localhost"
}

variable "commit_message_prefix" {
  description = <<DESCRIPTION
Prefix for auto-generated commit messages.
DESCRIPTION
  type        = string
  default     = "terraform: "
}

variable "auto_init" {
  description = <<DESCRIPTION
Whether to produce an initial commit with an empty README in the repository.
DESCRIPTION
  type        = bool
  default     = true
  nullable    = false
}

variable "gitignore_template" {
  description = <<DESCRIPTION
Gitignore template to use when creating the repository (e.g. Terraform, Python, Go).
DESCRIPTION
  type        = string
  default     = null
}

variable "license_template" {
  description = <<DESCRIPTION
License template to use when creating the repository (e.g. mit, apache-2.0).
DESCRIPTION
  type        = string
  default     = null
}

variable "archive_on_destroy" {
  description = <<DESCRIPTION
Archive the repository instead of deleting on destroy.
DESCRIPTION
  type        = bool
  default     = true
}

variable "has_issues" {
  description = <<DESCRIPTION
Enable GitHub Issues on the repository.
DESCRIPTION
  type        = bool
  default     = true
  nullable    = false
}

variable "has_projects" {
  description = <<DESCRIPTION
Enable GitHub Projects on the repository.
DESCRIPTION
  type        = bool
  default     = false
  nullable    = false
}

variable "has_wiki" {
  description = <<DESCRIPTION
Enable the wiki on the repository.
DESCRIPTION
  type        = bool
  default     = false
  nullable    = false
}

variable "is_template" {
  description = <<DESCRIPTION
Whether this repository is a template repository (usable as the source for
`Use this template` on other repos).
DESCRIPTION
  type        = bool
  default     = false
  nullable    = false
}

variable "allow_merge_commit" {
  description = <<DESCRIPTION
Allow merge-commit merges on pull requests.
DESCRIPTION
  type        = bool
  default     = true
  nullable    = false
}

variable "allow_squash_merge" {
  description = <<DESCRIPTION
Allow squash merges on pull requests.
DESCRIPTION
  type        = bool
  default     = true
  nullable    = false
}

variable "allow_rebase_merge" {
  description = <<DESCRIPTION
Allow rebase merges on pull requests.
DESCRIPTION
  type        = bool
  default     = true
  nullable    = false
}

variable "delete_branch_on_merge" {
  description = <<DESCRIPTION
Automatically delete head branches after pull requests are merged.
DESCRIPTION
  type        = bool
  default     = false
  nullable    = false
}

variable "vulnerability_alerts" {
  description = <<DESCRIPTION
Enable the repository's Dependabot vulnerability alerts.
DESCRIPTION
  type        = bool
  default     = false
  nullable    = false
}

variable "owner_is_organization" {
  description = <<DESCRIPTION
Whether the repository owner is a GitHub organization (`true`) or a personal user account (`false`).

This controls whether the module uses `github_organization` or `github_user` data source
to resolve OIDC claim values.
DESCRIPTION
  type        = bool
  default     = true
  nullable    = false
}

variable "actions_oidc_subject_claims" {
  description = <<DESCRIPTION
Customize the OIDC subject claim template for GitHub Actions in this repository.
Set to `null` to not manage this resource.

- `use_default` - Whether to use the default template provided by GitHub.
- `include_claim_keys` - List of claim keys to include in the subject claim
  (e.g. `repository_owner_id`, `repository_id`, `environment`).
DESCRIPTION
  type = object({
    use_default        = bool
    include_claim_keys = list(string)
  })
  default = {
    use_default = false
    include_claim_keys = [
      "repository_owner_id",
      "repository_id",
      "environment"
    ]
  }
}

variable "actions_oidc_subject_claim_values" {
  description = <<DESCRIPTION
Additional OIDC subject claim key/value pairs for keys that cannot be resolved
by the module at plan time (e.g. `job_workflow_ref`). These are merged with the
module-resolved values and used when constructing federated identity credential subjects.

The following keys are resolved automatically and cannot be overridden:
`repository`, `repository_id`, `repository_owner`, `repository_owner_id`,
`repository_visibility`, `environment`.
DESCRIPTION
  type        = map(string)
  default     = {}
  nullable    = false

  validation {
    condition = alltrue([
      for key in keys(var.actions_oidc_subject_claim_values) :
      !contains([
        "repository",
        "repository_id",
        "repository_owner",
        "repository_owner_id",
        "repository_visibility",
        "environment",
      ], key)
    ])
    error_message = "Cannot override module-managed claim keys: repository, repository_id, repository_owner, repository_owner_id, repository_visibility, environment."
  }
}
