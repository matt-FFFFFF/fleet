variable "environments" {
  description = <<DESCRIPTION
Map of environments to create for the repository.
The map key is an arbitrary identifier to avoid known-after-apply issues.

- `environment` - The name of the environment.
- `wait_timer` - Amount of time in minutes to delay a job after the job is initially triggered.
- `can_admins_bypass` - Whether repository admins can bypass the environment protections. Defaults to `true`.
- `prevent_self_review` - Whether users are prevented from approving workflows they triggered. Defaults to `false`.
- `reviewers` - Reviewers who may approve deployments:
  - `teams` - Up to 6 team IDs.
  - `users` - Up to 6 user IDs.
- `variables` - Map of environment variables (arbitrary key):
  - `name` - The variable name.
  - `value` - The variable value.
- `secrets` - Map of environment secrets (arbitrary key). Values are NOT managed by Terraform:
  - `name` - The secret name.
- `deployment_policy` - Deployment branch policy:
  - `protected_branches` - Whether only protected branches can deploy.
  - `custom_branch_policies` - Whether only matching branch/tag patterns can deploy.
- `branch_policies` - Branch name patterns for custom deployment policies.
- `tag_policies` - Tag name patterns for custom deployment policies.
- `identity` - Optional Azure identity configuration. When set, creates a user-assigned
  managed identity and federated identity credential for the environment:
  - `name` - Name of the user-assigned managed identity.
  - `parent_id` - Azure resource group resource ID where the identity will be created.
  - `location` - Azure region for the identity.
  - `subject` - Optional override for the federated identity credential subject claim.
    When not set, the subject is auto-constructed from the OIDC claim configuration.
  - `audiences` - Optional list of audiences for the federated credential. Defaults to `["api://AzureADTokenExchange"]`.
  - `fic_name` - Optional override for the federated identity credential resource name.
    When null or empty the FIC name defaults to `environment`.
- `identity_role_assignments` - Optional map of Azure role assignments for the environment's managed identity:
  - `role_definition_id` - The full resource ID of the role definition.
  - `scope` - The scope at which the role assignment applies.
  - `condition` - Optional condition for the role assignment.
  - `condition_version` - Optional version of the condition syntax (e.g. `"2.0"`).
DESCRIPTION
  type = map(object({
    environment         = string
    wait_timer          = optional(number, 0)
    can_admins_bypass   = optional(bool, true)
    prevent_self_review = optional(bool, false)
    reviewers = optional(object({
      teams = optional(set(number), [])
      users = optional(set(number), [])
    }))
    variables = optional(map(object({
      name  = string
      value = string
    })), {})
    secrets = optional(map(object({
      name = string
    })), {})
    deployment_policy = optional(object({
      protected_branches     = optional(bool, false)
      custom_branch_policies = optional(bool, false)
    }))
    branch_policies = optional(list(string), [])
    tag_policies    = optional(list(string), [])
    identity = optional(object({
      name      = string
      parent_id = string
      location  = string
      subject   = optional(string)
      audiences = optional(list(string), ["api://AzureADTokenExchange"])
      fic_name  = optional(string)
    }))
    identity_role_assignments = optional(map(object({
      role_definition_id = string
      scope              = string
      condition          = optional(string)
      condition_version  = optional(string)
    })), {})
  }))
  default  = {}
  nullable = false

  validation {
    condition = alltrue([
      for k, v in var.environments :
      length(v.branch_policies) == 0 || (v.deployment_policy != null && v.deployment_policy.custom_branch_policies)
    ])
    error_message = "branch_policies requires deployment_policy with custom_branch_policies = true."
  }

  validation {
    condition = alltrue([
      for k, v in var.environments :
      length(v.tag_policies) == 0 || (v.deployment_policy != null && v.deployment_policy.custom_branch_policies)
    ])
    error_message = "tag_policies requires deployment_policy with custom_branch_policies = true."
  }
}
