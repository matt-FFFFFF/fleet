# bootstrap/fleet variables.
#
# Fleet identity is sourced from clusters/_fleet.yaml via yamldecode
# (see main.tf locals). This file only declares inputs that do NOT
# belong in _fleet.yaml.

variable "fleet_repo_visibility" {
  description = "Visibility of the fleet repo (private|internal|public)."
  type        = string
  default     = "private"
}

variable "allow_public_state_during_bootstrap" {
  description = <<-EOT
    First-apply-only escape hatch. When `true`, the fleet tfstate storage
    account keeps `publicNetworkAccess = "Enabled"` (still with
    `defaultAction = "Deny"`) long enough for this apply to seed the
    private endpoint + optional DNS zone group. Flip back to `false` for
    every subsequent apply. Reruns require a VNet-reachable workstation
    (jump host / Bastion / VPN). See docs/adoption.md §5.
  EOT
  type        = bool
  default     = false
}
