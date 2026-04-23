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

variable "fleet_runners_app_pem" {
  description = <<-EOT
    PEM private key for the `fleet-runners` GitHub App.

    Auto-loaded from `.gh-apps.auto.tfvars` (written by `init-gh-apps.sh`,
    gitignored, mode 0600). Seeded into the fleet Key Vault as the
    `fleet-runners-app-pem` secret via the Key Vault data-plane API,
    using a write-only `sensitive_body` so the PEM never enters
    Terraform state and is discarded from memory after apply (ephemeral).

    Because the fleet KV has `publicNetworkAccess = Disabled`, the
    executor running this apply must have private-network reach to
    `<vault>.vault.azure.net` (VPN / jump host / Bastion). Rotate by
    re-running `init-gh-apps.sh` (or setting a new PEM in-place) and
    bumping the `fleet_runners_app_pem_version` variable.
  EOT
  type        = string
  sensitive   = true
  ephemeral   = true
  nullable    = false
}

variable "fleet_runners_app_pem_version" {
  description = <<-EOT
    Version tag for `fleet_runners_app_pem`. Bump this string whenever
    the PEM rotates so Terraform re-PUTs the secret to the Key Vault
    data plane. Opaque — any change triggers a new version. Because the
    PEM itself is ephemeral, Terraform cannot hash the value to detect
    rotations automatically.
  EOT
  type        = string
  default     = "0"
  nullable    = false
}
