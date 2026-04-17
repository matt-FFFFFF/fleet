variable "env" {
  description = "Environment name (mgmt | nonprod | prod | ...)"
  type        = string

  validation {
    condition     = can(regex("^[a-z][a-z0-9-]{1,15}$", var.env))
    error_message = "env must be lowercase alnum, 2-16 chars."
  }
}

variable "fleet" {
  description = "Pass-through of clusters/_fleet.yaml."
  type = object({
    name       = string
    tenant_id  = string
    github_org = string
    acr = object({
      name            = string
      resource_group  = string
      subscription_id = string
      location        = string
    })
    keyvault = object({
      name = string
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
    observability = object({
      network_isolation = object({
        mode                     = string
        nsp_profile_name         = string
        grafana_private_dns_zone = string
      })
      monitor_workspace        = object({ public_network_access = string })
      data_collection_endpoint = object({ public_network_access = string })
      action_group             = object({ short_name_prefix = string })
    })
  })
}

variable "environment" {
  description = "Env-scope block from _fleet.yaml:environments.<env>."
  type = object({
    subscription_id = string
    networking = object({
      grafana_pe_subnet_id       = string
      grafana_pe_linked_vnet_ids = list(string)
    })
    aks = object({
      admin_groups        = list(string)
      rbac_cluster_admins = list(string)
      rbac_readers        = list(string)
    })
    grafana = object({
      admins  = list(string)
      editors = list(string)
    })
    action_group = object({
      receivers = map(object({
        webhook_url_kv_secret     = optional(string)
        integration_key_kv_secret = optional(string)
      }))
    })
  })
}

variable "fleet_repo_name" {
  type    = string
  default = "fleet"
}

variable "env_reviewers_count" {
  description = "Required reviewers on the fleet-<env> GH environment."
  type        = number
  default     = 0

  validation {
    condition     = contains([0, 1, 2, 6], var.env_reviewers_count)
    error_message = "Must be 0 (nonprod/mgmt), 1 (mgmt), or 2 (prod)."
  }
}

variable "location" {
  description = "Azure region for env-scope RGs + observability stack."
  type        = string
}
