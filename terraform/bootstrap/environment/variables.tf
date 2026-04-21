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
  # generic "Invalid index" that local.fleet_doc.envs[var.env] would
  # otherwise throw via provider "azapi".subscription_id in providers.tf.
  validation {
    condition = contains(
      keys(try(yamldecode(file("${path.root}/../../../clusters/_fleet.yaml")).envs, {})),
      var.env,
    )
    error_message = format(
      "env %q is not declared in clusters/_fleet.yaml.envs; declared envs: %s",
      var.env,
      join(", ", keys(try(yamldecode(file("${path.root}/../../../clusters/_fleet.yaml")).envs, {}))),
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

# Mgmt VNet resource ids, published by `bootstrap/fleet`'s
# `main.github.tf` onto the `fleet-meta` GitHub Environment as the
# JSON-encoded `MGMT_VNET_RESOURCE_IDS` variable (shape
# `{ "<region>": "<arm-id>" }`). Wired into Phase-D mgmt↔env peering
# and, for env=mgmt runs, into the cluster-workload subnet carves on
# the pre-existing mgmt VNets.
#
# Declared here as a plain map(string) so the workflow can
# `fromJSON(vars.MGMT_VNET_RESOURCE_IDS)` and export each entry as
# individual TF_VAR values, OR pass the raw JSON via an intermediate
# variable. The recommended wiring is:
#
#   env:
#     TF_VAR_mgmt_vnet_resource_ids: ${{ vars.MGMT_VNET_RESOURCE_IDS }}
#
# which Terraform accepts as an HCL map literal in the tfvar channel
# (valid JSON is valid HCL-map syntax). Per-region keys are
# non-negotiable: every mgmt region named in
# `networking.envs.mgmt.regions` must appear here and resolve to a
# `/subscriptions/<sub>/resourceGroups/<rg>/providers/Microsoft.Network/virtualNetworks/<name>`
# resource id. The `Network Contributor` grant required to carve
# subnets / author reverse peerings on each of these VNets is already
# placed by `bootstrap/fleet/main.network.tf` on the fleet-meta UAMI.
#
# See PLAN §3.4 + docs/networking.md.
variable "mgmt_vnet_resource_ids" {
  description = "Map of mgmt region (e.g. \"eastus\") → resource id of the mgmt VNet authored by bootstrap/fleet (fed from MGMT_VNET_RESOURCE_IDS GH env variable)."
  type        = map(string)

  validation {
    condition = alltrue([
      for region, id in var.mgmt_vnet_resource_ids :
      can(regex("^/subscriptions/[0-9a-fA-F-]{36}/resourceGroups/[^/]+/providers/Microsoft\\.Network/virtualNetworks/[^/]+$", id))
    ])
    error_message = "Every mgmt_vnet_resource_ids value must be a `/subscriptions/<sub>/resourceGroups/<rg>/providers/Microsoft.Network/virtualNetworks/<name>` id. Sourced from the JSON-encoded MGMT_VNET_RESOURCE_IDS GH env variable published by bootstrap/fleet."
  }

  validation {
    condition     = length(var.mgmt_vnet_resource_ids) > 0
    error_message = "mgmt_vnet_resource_ids must not be empty; at least one mgmt region must be declared in networking.envs.mgmt.regions (and its id exported by bootstrap/fleet)."
  }
}
