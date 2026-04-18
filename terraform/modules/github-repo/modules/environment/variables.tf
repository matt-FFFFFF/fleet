variable "repository" {
  description = <<DESCRIPTION
The name of the repository to create the environment in.
DESCRIPTION
  type        = string
  nullable    = false
}

variable "environment" {
  description = <<DESCRIPTION
The name of the environment.
DESCRIPTION
  type        = string
  nullable    = false
}

variable "wait_timer" {
  description = <<DESCRIPTION
Amount of time in minutes to delay a job after the job is initially triggered.
DESCRIPTION
  type        = number
  default     = 0
}

variable "can_admins_bypass" {
  description = <<DESCRIPTION
Whether repository admins can bypass the environment protections. Defaults to true.
DESCRIPTION
  type        = bool
  default     = true
}

variable "prevent_self_review" {
  description = <<DESCRIPTION
Whether users are prevented from approving workflows runs that they triggered. Defaults to false.
DESCRIPTION
  type        = bool
  default     = false
}

variable "reviewers" {
  description = <<DESCRIPTION
Reviewers who may approve deployments to this environment.

- `teams` - Up to 6 team IDs who may review jobs that reference the environment.
- `users` - Up to 6 user IDs who may review jobs that reference the environment.
DESCRIPTION
  type = object({
    teams = optional(set(number), [])
    users = optional(set(number), [])
  })
  default = null
}

variable "variables" {
  description = <<DESCRIPTION
Map of environment variables to create.
The map key is an arbitrary identifier to avoid known-after-apply issues.

- `name` - The name of the environment variable.
- `value` - The value of the environment variable.
DESCRIPTION
  type = map(object({
    name  = string
    value = string
  }))
  default  = {}
  nullable = false
}

variable "secrets" {
  description = <<DESCRIPTION
Map of environment secrets to create. Values are NOT managed by Terraform.
The map key is an arbitrary identifier to avoid known-after-apply issues.

- `name` - The name of the secret.

Secrets are created with a placeholder and `lifecycle { ignore_changes }` on
`plaintext_value`. Set actual values via GitHub UI, CLI, or API after creation.
DESCRIPTION
  type = map(object({
    name = string
  }))
  default  = {}
  nullable = false
}

variable "deployment_policy" {
  description = <<DESCRIPTION
Deployment branch policy for the environment.

- `protected_branches` - Whether only branches with branch protection rules can deploy.
- `custom_branch_policies` - Whether only branches/tags matching specified patterns can deploy.
  Set to `true` to use `branch_policies` and `tag_policies` variables.
DESCRIPTION
  type = object({
    protected_branches     = optional(bool, false)
    custom_branch_policies = optional(bool, false)
  })
  default = null
}

variable "branch_policies" {
  description = <<DESCRIPTION
Branch name patterns for custom deployment policies.
Requires `deployment_policy` with `custom_branch_policies = true`.
DESCRIPTION
  type        = list(string)
  default     = []
  nullable    = false

  validation {
    condition     = length(var.branch_policies) == 0 || (var.deployment_policy != null && var.deployment_policy.custom_branch_policies)
    error_message = "branch_policies requires deployment_policy with custom_branch_policies = true."
  }
}

variable "tag_policies" {
  description = <<DESCRIPTION
Tag name patterns for custom deployment policies.
Requires `deployment_policy` with `custom_branch_policies = true`.
DESCRIPTION
  type        = list(string)
  default     = []
  nullable    = false

  validation {
    condition     = length(var.tag_policies) == 0 || (var.deployment_policy != null && var.deployment_policy.custom_branch_policies)
    error_message = "tag_policies requires deployment_policy with custom_branch_policies = true."
  }
}

# -----------------------------------------------------------------------------
# Azure identity
# -----------------------------------------------------------------------------

variable "identity" {
  description = <<DESCRIPTION
Optional Azure identity configuration for this environment. When set, creates a
user-assigned managed identity and a federated identity credential linked to the
GitHub Actions OIDC provider.

- `name` - Name of the user-assigned managed identity.
- `parent_id` - Azure resource group resource ID where the identity will be created.
- `location` - Azure region for the identity.
- `subject` - Optional override for the federated identity credential subject claim.
  When not set, the subject is auto-constructed from the OIDC claim configuration.
- `audiences` - Optional list of audiences for the federated credential.
  Defaults to `["api://AzureADTokenExchange"]`.
- `fic_name` - Optional override for the federated identity credential resource
  name. When null or empty the FIC name defaults to `var.environment`.
DESCRIPTION
  type = object({
    name      = string
    parent_id = string
    location  = string
    subject   = optional(string)
    audiences = optional(list(string), ["api://AzureADTokenExchange"])
    fic_name  = optional(string)
  })
  default = null
}

variable "actions_oidc_subject_claims" {
  description = <<DESCRIPTION
The OIDC subject claim configuration from the root module, used to determine
how to construct the federated identity credential subject string.
DESCRIPTION
  type = object({
    use_default        = bool
    include_claim_keys = list(string)
  })
  default = null
}

variable "oidc_subject_claim_values" {
  description = <<DESCRIPTION
Map of OIDC subject claim keys to their resolved values, passed from the root
module. Includes both module-resolved values (e.g. repository_id) and
user-supplied values (e.g. job_workflow_ref).
DESCRIPTION
  type        = map(string)
  default     = {}
  nullable    = false
}

variable "repository_full_name" {
  description = <<DESCRIPTION
The full name of the repository (owner/name), used to construct the default
OIDC subject claim format (repo:owner/name:environment:env-name).
DESCRIPTION
  type        = string
  default     = ""
  nullable    = false
}

# -----------------------------------------------------------------------------
# Azure role assignments
# -----------------------------------------------------------------------------

variable "role_assignments" {
  description = <<DESCRIPTION
Map of Azure role assignments for this environment's managed identity.
Requires `identity` to be configured.

- `role_definition_id` - The full resource ID of the role definition.
- `scope` - The scope at which the role assignment applies.
- `condition` - Optional condition for the role assignment.
- `condition_version` - Optional version of the condition syntax (e.g. `"2.0"`).
DESCRIPTION
  type = map(object({
    role_definition_id = string
    scope              = string
    condition          = optional(string)
    condition_version  = optional(string)
  }))
  default  = {}
  nullable = false

  validation {
    condition     = length(var.role_assignments) == 0 || var.identity != null
    error_message = "role_assignments requires identity to be configured."
  }
}
