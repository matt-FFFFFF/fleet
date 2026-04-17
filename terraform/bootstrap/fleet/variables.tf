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

# NOTE: `gh_repo_module_source` was declared here in an earlier draft as a
# placeholder for the org-maintained GH-repo module. Removed because tflint
# flagged it as unused and we prefer not to carry dead inputs. Reintroduce
# when the module wiring in main.github.tf is actually swapped in.
