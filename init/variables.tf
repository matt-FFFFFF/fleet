# Typed adopter inputs. Every variable carries a validation block; invalid
# values are rejected by `terraform apply` with a clear error message.
#
# The wrapper shell (../init-fleet.sh) prompts for any variable whose value
# in inputs.auto.tfvars is still the sentinel "__PROMPT__" and writes the
# filled-in values back before invoking apply.

variable "fleet_name" {
  description = "Short fleet slug; used in resource names. Lowercase alnum, starting with a letter, 2-12 chars."
  type        = string
  validation {
    condition     = can(regex("^[a-z][a-z0-9]{1,11}$", var.fleet_name))
    error_message = "fleet_name must match ^[a-z][a-z0-9]{1,11}$ (2-12 chars, lowercase alnum, letter first)."
  }
}

variable "fleet_display_name" {
  description = "Human-friendly fleet name (appears in README and Grafana)."
  type        = string
  validation {
    condition     = length(var.fleet_display_name) > 0
    error_message = "fleet_display_name must be non-empty."
  }
}

variable "tenant_id" {
  description = "Entra tenant GUID."
  type        = string
  validation {
    condition     = can(regex("^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$", var.tenant_id))
    error_message = "tenant_id must be a GUID."
  }
}

variable "github_org" {
  description = "GitHub org or user that owns the fleet repo."
  type        = string
  validation {
    # GitHub org/user rules: 1-39 chars, alnum at both ends, single hyphens
    # between alnum segments (no leading/trailing hyphen, no `--`).
    condition     = length(var.github_org) <= 39 && can(regex("^[A-Za-z0-9]+(-[A-Za-z0-9]+)*$", var.github_org))
    error_message = "github_org must be 1-39 characters of letters or digits, with single hyphens only between alphanumeric segments."
  }
}

variable "github_repo" {
  description = "Name of the fleet repo on GitHub."
  type        = string
  default     = "platform-fleet"
  validation {
    condition     = can(regex("^[A-Za-z0-9._-]+$", var.github_repo))
    error_message = "github_repo must match ^[A-Za-z0-9._-]+$."
  }
}

variable "team_template_repo" {
  description = "Name of the team template repo on GitHub."
  type        = string
  default     = "team-repo-template"
  validation {
    condition     = can(regex("^[A-Za-z0-9._-]+$", var.team_template_repo))
    error_message = "team_template_repo must match ^[A-Za-z0-9._-]+$."
  }
}

variable "primary_region" {
  description = "Primary Azure region (e.g. eastus)."
  type        = string
  default     = "eastus"
  validation {
    condition     = can(regex("^[a-z0-9]+$", var.primary_region))
    error_message = "primary_region must be a lowercase-alnum Azure location short name."
  }
}

variable "sub_shared" {
  description = "Subscription GUID for shared resources (ACR, state, fleet KV)."
  type        = string
  validation {
    condition     = can(regex("^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$", var.sub_shared))
    error_message = "sub_shared must be a GUID."
  }
}

variable "sub_mgmt" {
  description = "Subscription GUID for the mgmt environment."
  type        = string
  validation {
    condition     = can(regex("^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$", var.sub_mgmt))
    error_message = "sub_mgmt must be a GUID."
  }
}

variable "sub_nonprod" {
  description = "Subscription GUID for the nonprod environment."
  type        = string
  validation {
    condition     = can(regex("^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$", var.sub_nonprod))
    error_message = "sub_nonprod must be a GUID."
  }
}

variable "sub_prod" {
  description = "Subscription GUID for the prod environment."
  type        = string
  validation {
    condition     = can(regex("^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$", var.sub_prod))
    error_message = "sub_prod must be a GUID."
  }
}

variable "dns_fleet_root" {
  description = "DNS root zone under which per-cluster private zones are created (e.g. int.acme.example)."
  type        = string
  validation {
    condition     = can(regex("^[a-z0-9]([a-z0-9-]*[a-z0-9])?(\\.[a-z0-9]([a-z0-9-]*[a-z0-9])?)+$", var.dns_fleet_root))
    error_message = "dns_fleet_root must be a lowercase DNS name like int.acme.example."
  }
}

variable "template_commit" {
  description = "Template repo commit SHA at init time (populated by the wrapper shell; leave empty for local runs)."
  type        = string
  default     = "unknown"
}
