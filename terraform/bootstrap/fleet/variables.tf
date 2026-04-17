# bootstrap/fleet variables.
#
# Populated from clusters/_fleet.yaml via a terraform.tfvars.json emitted
# by the operator (or produced by a helper script — see docs/bootstrap.md).

variable "fleet" {
  description = "Full _fleet.yaml contents (fleet, acr, keyvault, state, aad.*, dns)."
  type = object({
    name       = string
    tenant_id  = string
    github_org = string
    acr = object({
      name            = string
      resource_group  = string
      subscription_id = string
      location        = string
      sku             = string
    })
    keyvault = object({
      name           = string
      resource_group = string
      location       = string
    })
    state = object({
      storage_account = string
      resource_group  = string
      subscription_id = string
      containers = object({
        fleet = string
      })
    })
    dns = object({
      fleet_root             = string
      resource_group_pattern = optional(string, "rg-dns-{env}")
    })
  })
}

variable "fleet_repo_name" {
  description = "GitHub repo name for the fleet monorepo (owner comes from fleet.github_org)."
  type        = string
  default     = "fleet"
}

variable "team_template_repo_name" {
  description = "GitHub repo name for the team-repo template."
  type        = string
  default     = "team-repo-template"
}

variable "fleet_repo_visibility" {
  description = "Visibility of the fleet repo (private|internal|public)."
  type        = string
  default     = "private"
}

variable "gh_repo_module_source" {
  description = <<-EOT
    Source of the org-maintained GH-repo Terraform module. Left as a
    placeholder for Phase 1 — the module wiring is stubbed (see
    main.github.tf). Replace with the published module path when known.
  EOT
  type        = string
  default     = "PLACEHOLDER: github.com/<org>/terraform-github-repo//module"
}

variable "fleet_stage0_fic_subject" {
  description = "Federated-credential subject for the fleet-stage0 UAMI."
  type        = string
  default     = "repo:<org>/<fleet-repo>:environment:fleet-stage0"
}

variable "fleet_meta_fic_subject" {
  description = "Federated-credential subject for the fleet-meta UAMI."
  type        = string
  default     = "repo:<org>/<fleet-repo>:environment:fleet-meta"
}
