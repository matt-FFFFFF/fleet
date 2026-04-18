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
