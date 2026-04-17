# bootstrap/fleet variables.
#
# Fleet identity is sourced from clusters/_fleet.yaml via yamldecode
# (see main.tf locals). This file only declares inputs that do NOT
# belong in _fleet.yaml: GitHub auth token and the federated-credential
# subjects (which depend on the rendered repo slug).

variable "fleet_stage0_fic_subject" {
  description = <<-EOT
    Federated-credential subject for the fleet-stage0 UAMI. Default is
    computed from _fleet.yaml (`repo:<org>/<repo>:environment:fleet-stage0`).
    Override only for non-standard repo names or testing.
  EOT
  type        = string
  default     = ""
}

variable "fleet_meta_fic_subject" {
  description = "Same as fleet_stage0_fic_subject but for fleet-meta."
  type        = string
  default     = ""
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
