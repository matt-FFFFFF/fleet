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

# Mgmt VNet resource id, published by `bootstrap/fleet`'s `main.github.tf`
# onto the `fleet-meta` GitHub Environment as the `MGMT_VNET_RESOURCE_ID`
# variable. Wired into Phase-D mgmt↔env peering: this stage authors the
# env half locally and (via `create_reverse_peering = true` on the
# peering AVM submodule) the reverse half against this id. The
# `Network Contributor` grant for that PUT is already issued on the mgmt
# VNet to `uami-fleet-meta` by `bootstrap/fleet/main.network.tf`.
#
# See PLAN §3.4 + docs/networking.md.
variable "mgmt_vnet_resource_id" {
  description = "Resource id of the mgmt VNet authored by bootstrap/fleet (from MGMT_VNET_RESOURCE_ID env var)."
  type        = string

  validation {
    condition     = can(regex("^/subscriptions/[0-9a-fA-F-]{36}/resourceGroups/[^/]+/providers/Microsoft\\.Network/virtualNetworks/[^/]+$", var.mgmt_vnet_resource_id))
    error_message = "mgmt_vnet_resource_id must be a /subscriptions/<sub>/resourceGroups/<rg>/providers/Microsoft.Network/virtualNetworks/<name> id (typically supplied via TF_VAR_mgmt_vnet_resource_id from the MGMT_VNET_RESOURCE_ID GH env variable)."
  }
}
