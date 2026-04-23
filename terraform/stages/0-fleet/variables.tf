# stages/0-fleet variables.
#
# Fleet identity is sourced from clusters/_fleet.yaml (see main.tf locals).
#
# Networking inputs (PLAN §3.4): `bootstrap/fleet` publishes per-region
# mgmt subnet ids as JSON-encoded `{ region => resource_id }` maps on the
# `fleet-stage0` GitHub Actions environment. Stage 0's workflow passes
# them in as tfvars (e.g. `mgmt_pe_fleet_subnet_ids =
# fromjson(vars.MGMT_PE_FLEET_SUBNET_IDS)`). Stage 0 picks the mgmt
# region co-located with the fleet ACR (`acr.location` in _fleet.yaml)
# via same-region-else-first and lands its ACR private endpoint there.
#
# PLAN §4 Stage 0 additionally specifies GitHub App inputs
# (`fleet_meta_app_id`, `fleet_meta_app_pem`,
#  `fleet_meta_app_webhook_secret`, `fleet_meta_app_client_id`,
#  `stage0_publisher_app_id`, `stage0_publisher_app_pem`,
#  `stage0_publisher_app_webhook_secret`,
#  `stage0_publisher_app_client_id`)
# to be consumed from a tfvars file derived at apply time from
# `<repo-root>/.gh-apps.state.json` (the authoritative on-disk record
# written at the repo root by the implemented `init-gh-apps.sh`
# helper described in PLAN §16.4). From Stage 0's working directory
# (`terraform/stages/0-fleet/`) that file lives three levels up; the
# apply-time derivation step must reference it via an explicit path
# (`$(git rev-parse --show-toplevel)/.gh-apps.state.json` in the
# workflow, or `../../../.gh-apps.state.json` relative to the module
# root). The deferred work here is the Stage 0 `variable` blocks and
# the KV-seed / repo-variable-publish resources that consume tfvars
# derived from that file at apply time; those pieces intentionally do
# not ship in this scaffold yet.

variable "mgmt_pe_fleet_subnet_ids" {
  description = <<-EOT
    Map of `region => <snet-pe-fleet resource id>` for every mgmt env-
    region. Populated in CI from `fromjson(vars.MGMT_PE_FLEET_SUBNET_IDS)`
    (published by `bootstrap/fleet/main.github.tf` on the `fleet-meta`
    env; the `fleet-stage0` env mirrors it for Stage 0 consumption).
    Stage 0 selects `acr.location` (same-region-else-first) and lands
    the fleet ACR PE in that subnet. PLAN §3.4.
  EOT
  type        = map(string)

  validation {
    condition     = length(var.mgmt_pe_fleet_subnet_ids) > 0
    error_message = "mgmt_pe_fleet_subnet_ids must contain at least one mgmt region entry. Ensure `bootstrap/fleet` has been applied and the `MGMT_PE_FLEET_SUBNET_IDS` repo variable is populated on the `fleet-stage0` environment."
  }

  validation {
    condition = alltrue([
      for k, v in var.mgmt_pe_fleet_subnet_ids :
      can(regex("^/subscriptions/[0-9a-fA-F-]{36}/resourceGroups/[^/]+/providers/Microsoft\\.Network/virtualNetworks/[^/]+/subnets/snet-pe-fleet$", v))
    ])
    error_message = "Every entry in mgmt_pe_fleet_subnet_ids must be a full ARM subnet resource id ending in `/subnets/snet-pe-fleet`."
  }
}
