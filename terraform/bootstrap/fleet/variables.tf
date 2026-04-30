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

variable "fleet_meta_app_pem" {
  description = <<-EOT
    PEM private key for the `fleet-meta` GitHub App.

    Auto-loaded from `.gh-apps.auto.tfvars` (written by `init-gh-apps.sh`,
    gitignored, mode 0600). Seeded into the fleet Key Vault as the
    `fleet-meta-app-pem` secret via the Key Vault data-plane API,
    using a write-only `sensitive_body` so the PEM never enters
    Terraform state and is discarded from memory after apply (ephemeral).

    Read at runtime by the `env-bootstrap.yaml` and `team-bootstrap.yaml`
    workflows: `azure/login` (uami-fleet-meta) → `az keyvault secret show`
    → `actions/create-github-app-token` → `GITHUB_TOKEN` for the
    Terraform `github` provider in `bootstrap/environment` and
    `bootstrap/team`.

    Rotate by re-running `init-gh-apps.sh` (or setting a new PEM
    in-place) and bumping the `fleet_meta_app_pem_version` variable.
  EOT
  type        = string
  sensitive   = true
  ephemeral   = true
  nullable    = false
}

variable "fleet_meta_app_pem_version" {
  description = <<-EOT
    Version tag for `fleet_meta_app_pem`. Bump this string whenever
    the PEM rotates so Terraform re-PUTs the secret to the Key Vault
    data plane. Opaque — any change triggers a new version.
  EOT
  type        = string
  default     = "0"
  nullable    = false
}

# -----------------------------------------------------------------------------
# Argo + Kargo AAD-app inputs.
#
# `mgmt_cluster_kv_id` is the chicken-and-egg switch that gates the
# OIDC RP `client_secret` writes into the mgmt cluster KV. It must be
# null on the first apply (before Stage 1 mgmt creates the KV) and
# set to the value of `vars.MGMT_CLUSTER_KV_ID` (published by Stage 1
# mgmt) on every subsequent apply. See `docs/adoption.md` two-pass
# bootstrap section.
#
# `argocd_rp_secret_version` / `kargo_rp_secret_version` are opaque
# tokens that gate password rotation; bumping either re-creates the
# matching `azuread_application_password` with a fresh value and a
# fresh 2-year `end_date`, then re-PUTs the secret to the mgmt
# cluster KV. Default "0" means no rotation.
# -----------------------------------------------------------------------------

variable "mgmt_cluster_kv_id" {
  description = <<-EOT
    Resource ID of the mgmt cluster Key Vault (Stage 1 mgmt output,
    published as `vars.MGMT_CLUSTER_KV_ID`). Null on first apply
    (Stage 1 mgmt has not run yet); set on second apply so Argo and
    Kargo OIDC RP `client_secret` values are written into the KV.
    Two-pass apply per PLAN §4 Stage -1.
  EOT
  type        = string
  default     = null
}

variable "argocd_rp_secret_version" {
  description = <<-EOT
    Opaque rotation token for the Argo OIDC RP `client_secret`. Bump
    to re-roll. Each new value triggers a fresh
    `azuread_application_password` with a 2-year `end_date` and a
    re-PUT into the mgmt cluster KV.
  EOT
  type        = string
  default     = "0"
  nullable    = false
}

variable "kargo_rp_secret_version" {
  description = <<-EOT
    Opaque rotation token for the Kargo OIDC RP `client_secret`. Bump
    to re-roll. Each new value triggers a fresh
    `azuread_application_password` with a 2-year `end_date` and a
    re-PUT into the mgmt cluster KV.
  EOT
  type        = string
  default     = "0"
  nullable    = false
}
