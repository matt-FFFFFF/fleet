# modules/cluster-dns/variables.tf

variable "zone_fqdn" {
  description = "Fully-qualified private DNS zone name (e.g. `aks-nonprod-01.eastus.nonprod.int.acme.example`). Derived by config-loader per PLAN §3.3; never authored by hand."
  type        = string
  nullable    = false
}

variable "parent_id" {
  description = "Resource group ARM id that will own the private DNS zone (`rg-dns-<env>` by default; overridable via `platform.dns.resource_group`)."
  type        = string
  nullable    = false
}

variable "linked_vnet_ids" {
  description = <<-EOT
    Map of logical key → VNet ARM id. One `virtualNetworkLinks` child is
    authored per entry. The key is reused as the link resource name
    (`link-<key>`) so adding a link is an additive diff. Stage 1 passes
    `{ env = <env-region VNet>, mgmt = <mgmt VNet> }` per PLAN §3.4.
  EOT
  type     = map(string)
  nullable = false
  validation {
    condition     = length(var.linked_vnet_ids) > 0
    error_message = "At least one linked VNet is required; an unlinked private DNS zone is unreachable from any client."
  }
}

variable "tags" {
  description = "Tags applied to the zone + link resources."
  type        = map(string)
  default     = {}
  nullable    = false
}
