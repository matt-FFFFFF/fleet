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

variable "fleet_github_owner_id" {
  description = <<-EOT
    Numeric GitHub org/user owner id (from data.github_organization.id /
    data.github_user.id, resolved by bootstrap/fleet under operator
    credentials). Wired in via `TF_VAR_fleet_github_owner_id:
    $${{ vars.FLEET_GITHUB_OWNER_ID }}`. Used to construct the
    repository_owner_id OIDC subject claim for the fleet-<env> UAMI's
    federated credential.

    The value cannot be looked up here via `data.github_organization`
    because the fleet-meta GitHub App that authenticates this bootstrap
    has no `Members: read` org permission.
  EOT
  type        = string

  validation {
    condition     = can(regex("^[0-9]+$", var.fleet_github_owner_id))
    error_message = "fleet_github_owner_id must be a numeric GitHub owner id."
  }
}

variable "fleet_github_repo_id" {
  description = <<-EOT
    Numeric GitHub repository id (from data.github_repository.repo_id,
    resolved by bootstrap/fleet). Wired in via
    `TF_VAR_fleet_github_repo_id: $${{ vars.FLEET_GITHUB_REPO_ID }}`.
    Used to construct the repository_id OIDC subject claim for the
    fleet-<env> UAMI's federated credential.
  EOT
  type        = string

  validation {
    condition     = can(regex("^[0-9]+$", var.fleet_github_repo_id))
    error_message = "fleet_github_repo_id must be a numeric GitHub repository id."
  }
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

# Mgmt VNet `snet-pe-fleet` subnet ids per mgmt region. Published by
# `bootstrap/fleet` onto the `fleet-meta` GH environment as the JSON-
# encoded `MGMT_PE_FLEET_SUBNET_IDS` repo/env variable; wired in via
# `TF_VAR_mgmt_pe_fleet_subnet_ids: ${{ vars.MGMT_PE_FLEET_SUBNET_IDS }}`
# in `.github/workflows/env-bootstrap.yaml`.
#
# Required only on env=mgmt runs (where this stage creates the fleet ACR
# and its PE in the co-located mgmt VNet). Non-mgmt env runs (nonprod,
# prod) may pass `'{}'`; the variable is unused there. Consequently the
# non-empty check is enforced via the `fleet_acr_pe` precondition (which
# dereferences `var.mgmt_pe_fleet_subnet_ids[local.acr_mgmt_region]`)
# rather than as a variable validation, so non-mgmt runs are not blocked.
variable "mgmt_pe_fleet_subnet_ids" {
  description = <<-EOT
    Map of `region => <snet-pe-fleet resource id>` for every mgmt env-region.
    Populated in CI from `vars.MGMT_PE_FLEET_SUBNET_IDS` (published by
    `bootstrap/fleet`). On env=mgmt runs the fleet ACR PE lands in
    `snet-pe-fleet` of the mgmt region co-located with `acr.location`
    (same-region-else-first); on non-mgmt runs the variable is unused and
    can be `{}`. PLAN §3.4.
  EOT
  type        = map(string)
  default     = {}

  validation {
    condition = alltrue([
      for k, v in var.mgmt_pe_fleet_subnet_ids :
      can(regex("^/subscriptions/[0-9a-fA-F-]{36}/resourceGroups/[^/]+/providers/Microsoft\\.Network/virtualNetworks/[^/]+/subnets/snet-pe-fleet$", v))
    ])
    error_message = "Every entry in mgmt_pe_fleet_subnet_ids must be a full ARM subnet resource id ending in `/subnets/snet-pe-fleet`."
  }
}
