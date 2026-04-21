# modules/aks-cluster/variables.tf
#
# Thin wrapper around `Azure/avm-res-containerservice-managedcluster/azurerm`
# (pinned ~> 0.5 in main.tf). Input surface is deliberately *curated*:
# each variable maps 1:1 to an AVM input or is hard-coded inside the
# module per PLAN §4 Stage 1. Operators tune AKS behaviour via a
# bounded set of `cluster.aks.*` keys in `cluster.yaml`, and adding a
# new knob means editing this file — there is no freeform `extra` /
# `passthrough` escape hatch by design. Rationale: Phase E lands the
# minimal set (version, SKU, autoscaler, auto-upgrade); expansion
# happens commit-by-commit as real needs emerge. `maintenance_window`
# was added as a follow-up and is authored via the sibling
# `//modules/maintenanceconfiguration` AVM submodule (same pattern as
# the additional-agent-pool submodule).
#
# Hard-coded (NOT variables):
#   - `oidc_issuer_profile.enabled = true`      — Stage 2 FICs require it.
#   - `security_profile.workload_identity.enabled = true` — workload identity.
#   - `disable_local_accounts = true`            — Entra-only auth (PLAN §4).
#   - `enable_rbac = true`                       — Azure RBAC for K8s.
#   - `aad_profile.managed = true`, `enable_azure_rbac = true`.
#   - `api_server_access_profile.{enable_private_cluster,enable_vnet_integration}`
#     = true — private cluster with api-server VNet integration on the
#     /28 subnet this module consumes.
#   - `network_profile.{network_plugin=azure, network_plugin_mode=overlay,
#     network_dataplane=cilium, network_policy=cilium,
#     load_balancer_sku=standard, outbound_type=userDefinedRouting}`.
#     UDR requires a route table on the node subnet that points
#     0.0.0.0/0 at the hub firewall's private IP. That route table +
#     subnet association is **not yet authored** — see PLAN §3.4
#     Implementation status (UDR for AKS node egress) + the
#     `networking.egress_next_hop_ip` stub in per-region
#     `_defaults.yaml`. Until that follow-up lands, `terraform plan`
#     succeeds but `terraform apply` against a live tenant will be
#     rejected by ARM for lacking a 0.0.0.0/0 route on the node
#     subnet; this is by design so the two halves ship atomically.
#     `outbound_type` itself is set at cluster creation and cannot be
#     changed later.

variable "cluster_name" {
  description = "AKS managed-cluster resource name (typically `cluster.name` from cluster.yaml)."
  type        = string
  nullable    = false
}

variable "location" {
  description = "Azure region (e.g. `eastus`). Must match the env VNet's region."
  type        = string
  nullable    = false
}

variable "parent_id" {
  description = "Resource group ARM id under which the managed cluster + linked resources are authored. The AVM module uses `parent_id` rather than `resource_group_name`."
  type        = string
  nullable    = false
}

# --- Networking inputs (from Stage 1) --------------------------------------

variable "api_subnet_id" {
  description = "Full ARM id of the per-cluster `/28` `snet-aks-api-<name>` subnet. Fed to `api_server_access_profile.subnet_id` with api-server VNet integration on."
  type        = string
  nullable    = false
}

variable "node_subnet_id" {
  description = "Full ARM id of the per-cluster `/25` `snet-aks-nodes-<name>` subnet. Fed to `default_agent_pool.vnet_subnet_id` and every additional agent-pool submodule call."
  type        = string
  nullable    = false
}

variable "node_asg_ids" {
  description = "List of Application Security Group resource ids attached to every node pool via `network_profile.application_security_groups`. Stage 1 passes the single shared env-region `asg-nodes-<env>-<region>` id."
  type        = list(string)
  default     = []
  nullable    = false
}

# --- AAD / RBAC ------------------------------------------------------------

variable "aad" {
  description = "Entra auth inputs. `tenant_id` is fleet-wide (`_fleet.yaml.aad.aks.tenant_id`); `admin_group_object_ids` is env-scope break-glass (`environments.<env>.aks.admin_groups`)."
  type = object({
    tenant_id              = string
    admin_group_object_ids = optional(list(string), [])
  })
  nullable = false
}

# --- Curated passthrough (cluster.aks.*) -----------------------------------
#
# Each variable below corresponds to exactly one AVM input. Adding a
# knob = adding a variable here + one line in main.tf. No freeform map.

variable "kubernetes_version" {
  description = "AVM `kubernetes_version`. From `kubernetes.version` in the cluster's merged yaml."
  type        = string
  default     = null
}

variable "sku_tier" {
  description = "AVM `sku = { tier }`. From `kubernetes.sku_tier`. Valid: Free, Standard, Premium."
  type        = string
  default     = "Standard"
  nullable    = false
}

variable "auto_scaler_profile" {
  description = "AVM `auto_scaler_profile` (cluster-autoscaler tuning). From `kubernetes.cluster_autoscaler_profile`. See AVM docs for the full attribute list."
  type        = any
  default     = null
}

variable "auto_upgrade_profile" {
  description = "AVM `auto_upgrade_profile` — `upgrade_channel` (control plane) and `node_os_upgrade_channel`. From `kubernetes.control_plane_upgrade` + `kubernetes.node_image_upgrade`."
  type = object({
    upgrade_channel         = optional(string)
    node_os_upgrade_channel = optional(string)
  })
  default = null
}

variable "maintenance_window" {
  description = <<-EOT
    Scheduled maintenance window for the managed cluster. Instantiated
    via `Azure/avm-res-containerservice-managedcluster/azurerm//modules/maintenanceconfiguration`
    when non-null (a single maintenance configuration named
    `aksManagedAutoUpgradeSchedule` — the magic name AKS expects for
    the control-plane + node-image auto-upgrade schedule — is authored
    under the cluster). Null skips creation.

    Shape mirrors the AVM submodule's typed input exactly — see the
    submodule README for field semantics. From `kubernetes.maintenance`
    in the merged cluster yaml. Exactly one of `schedule.{daily, weekly,
    absolute_monthly, relative_monthly}` must be set; `duration_hours`
    must be 4-24; `start_time` is `HH:MM`; `utc_offset` is `+/-HH:MM`.
  EOT
  type = object({
    duration_hours = number
    not_allowed_dates = optional(list(object({
      end   = string
      start = string
    })))
    schedule = object({
      absolute_monthly = optional(object({
        day_of_month    = number
        interval_months = number
      }))
      daily = optional(object({
        interval_days = number
      }))
      relative_monthly = optional(object({
        day_of_week     = string
        interval_months = number
        week_index      = string
      }))
      weekly = optional(object({
        day_of_week    = string
        interval_weeks = number
      }))
    })
    start_date = optional(string)
    start_time = string
    utc_offset = optional(string)
  })
  default = null

  validation {
    condition     = var.maintenance_window == null || (var.maintenance_window.duration_hours >= 4 && var.maintenance_window.duration_hours <= 24)
    error_message = "maintenance_window.duration_hours must be between 4 and 24 inclusive."
  }
  validation {
    condition     = var.maintenance_window == null || can(regex("^\\d{2}:\\d{2}$", var.maintenance_window.start_time))
    error_message = "maintenance_window.start_time must match HH:MM (e.g. 02:00)."
  }
  validation {
    condition     = var.maintenance_window == null || var.maintenance_window.utc_offset == null || can(regex("^(-|\\+)[0-9]{2}:[0-9]{2}$", var.maintenance_window.utc_offset))
    error_message = "maintenance_window.utc_offset must match +/-HH:MM (e.g. +00:00)."
  }
  validation {
    condition = var.maintenance_window == null || length([
      for k, v in {
        absolute_monthly = var.maintenance_window.schedule.absolute_monthly
        daily            = var.maintenance_window.schedule.daily
        relative_monthly = var.maintenance_window.schedule.relative_monthly
        weekly           = var.maintenance_window.schedule.weekly
      } : k if v != null
    ]) == 1
    error_message = "maintenance_window.schedule must have exactly one of {daily, weekly, absolute_monthly, relative_monthly} set."
  }
}

# --- Node pool inputs ------------------------------------------------------
#
# The AVM module exposes only `default_agent_pool` at the root; additional
# pools are created by the sibling `modules/agentpool` submodule (see
# main.tf). We accept two object inputs — system (→ default_agent_pool)
# and apps (→ one agentpool submodule call). A future commit may widen
# to a map for arbitrary extra pools, but every cluster today ships
# with exactly the {system, apps} pair from _defaults.yaml.

variable "system_pool" {
  description = "System node pool config from `node_pools.system` in cluster YAML. Mapped to `default_agent_pool.*` on the AVM module."
  type = object({
    vm_size             = optional(string, "Standard_D4s_v5")
    min_count           = optional(number, 2)
    max_count           = optional(number, 5)
    zones               = optional(list(string), ["1", "2", "3"])
    enable_auto_scaling = optional(bool, true)
    os_disk_size_gb     = optional(number)
    os_disk_type        = optional(string, "Ephemeral")
    max_pods            = optional(number, 250)
    node_labels         = optional(map(string), {})
    node_taints         = optional(list(string), ["CriticalAddonsOnly=true:NoSchedule"])
  })
  default  = {}
  nullable = false
}

variable "apps_pool" {
  description = "Apps (user) node pool config from `node_pools.apps`. When null the module creates only the system pool. Mapped to a single `agentpool` submodule call."
  type = object({
    vm_size             = optional(string, "Standard_D8s_v5")
    min_count           = optional(number, 3)
    max_count           = optional(number, 20)
    zones               = optional(list(string), ["1", "2", "3"])
    enable_auto_scaling = optional(bool, true)
    os_disk_size_gb     = optional(number)
    os_disk_type        = optional(string, "Ephemeral")
    max_pods            = optional(number, 250)
    node_labels         = optional(map(string), {})
    node_taints         = optional(list(string), [])
  })
  default = null
}

variable "tags" {
  description = "Tags applied to the AKS resource. Node-pool-level tags inherit from this map today; broaden later if a per-pool split is needed."
  type        = map(string)
  default     = {}
  nullable    = false
}
