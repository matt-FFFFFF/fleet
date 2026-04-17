# bootstrap/environment variables.
#
# Fleet identity is sourced from clusters/_fleet.yaml (see main.tf locals).
# Only env-scope inputs live here.

variable "env" {
  description = "Environment name (mgmt | nonprod | prod | ...)"
  type        = string

  validation {
    condition     = can(regex("^[a-z][a-z0-9-]{1,15}$", var.env))
    error_message = "env must be lowercase alnum, 2-16 chars."
  }

  # Assert that the env is actually declared in _fleet.yaml. Validation runs
  # before any local/provider/resource evaluation, so this replaces the
  # generic "Invalid index" that local.fleet_doc.environments[var.env] would
  # otherwise throw via provider "azapi".subscription_id in providers.tf.
  validation {
    condition = contains(
      keys(try(yamldecode(file("${path.root}/../../../clusters/_fleet.yaml")).environments, {})),
      var.env,
    )
    error_message = format(
      "env %q is not declared in clusters/_fleet.yaml.environments; declared envs: %s",
      var.env,
      join(", ", keys(try(yamldecode(file("${path.root}/../../../clusters/_fleet.yaml")).environments, {}))),
    )
  }
}

variable "env_reviewers_count" {
  description = "Required reviewers on the fleet-<env> GH environment."
  type        = number
  default     = 0

  validation {
    condition     = contains([0, 1, 2, 6], var.env_reviewers_count)
    error_message = "Must be 0 (nonprod/mgmt), 1 (mgmt), or 2 (prod)."
  }
}

variable "location" {
  description = "Azure region override for env-scope RGs + observability stack. Defaults to fleet.primary_region."
  type        = string
  default     = ""
}

variable "fleet_meta_principal_id" {
  description = "principalId of uami-fleet-meta (from bootstrap/fleet outputs)."
  type        = string
}
