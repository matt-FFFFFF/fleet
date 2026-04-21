# stages/1-cluster
#
# Per-cluster TF stack, one apply per cluster, driven by
# `config-loader/load.sh <clusters/<env>/<region>/<name>>` → merged
# tfvars.json. See PLAN §4 Stage 1.
#
# **Scope of the current implementation** — Phase E of PLAN §3.4 landed
# the *networking* half of Stage 1:
#
#   - main.network.tf : per-cluster /28 api + /25 nodes subnets as
#                       children of the env VNet
#   - modules/aks-cluster : thin wrapper around
#                       Azure/avm-res-containerservice-managedcluster/azurerm
#                       with the networking inputs (subnets, node-pool ASG)
#                       wired; pod CIDR is a fleet-wide constant
#                       (100.64.0.0/16) hard-coded inside the module
#   - modules/cluster-dns : private DNS zone + virtualNetworkLinks to
#                       [env VNet, mgmt VNet]
#
# **Still TODO** (tracked in STATUS.md §4 Stage 1) — these land when
# Stage 1 is promoted out of Phase E:
#   - Cluster Key Vault (+ KV Secrets User on ESO UAMI)
#   - UAMIs: external-dns, ESO, per-team
#   - Role assignments: AcrPull (kubelet), fleet KV Secrets User (ESO),
#     RBAC Cluster Admin (fleet-<env> UAMI), RBAC Reader (Kargo mgmt UAMI),
#     Monitoring Metrics Publisher (AKS addon → env AMW)
#   - Managed Prometheus wiring (DCR, DCRA, prometheusRuleGroups)
#   - Mgmt-cluster-only: Kargo RP secret rotation + KV write
#
# Inputs arrive via the loader-produced tfvars.json; no provider data
# sources at plan time (PLAN §10). Cross-stage values (MGMT_VNET_RESOURCE_ID,
# <ENV>_<REGION>_VNET_RESOURCE_ID, etc.) flow in as repo/env variables
# (TF_VAR_*) published directly by `bootstrap/fleet` and
# `bootstrap/environment` — Stage 0 does **not** proxy them (see PLAN §4
# Stage -1 "Implementation status 2026-04-19" for the cycle-break
# rationale).

locals {
  # Whole fleet doc + per-cluster merged doc. `var.doc` is the loader
  # output; we lift frequently-accessed sub-blocks to locals for
  # readability. Silence-on-absence is the loader contract (see
  # config-loader/load.sh); non-null fields are asserted via
  # lifecycle.precondition on the resources that consume them.
  cluster    = var.doc.cluster
  fleet      = var.doc.fleet.fleet
  derived    = var.doc.derived
  net        = var.doc.derived.networking
  kubernetes = try(var.doc.kubernetes, {})
  # Fleet-wide AKS policy (tenant_id, disable_local_accounts,
  # enable_azure_rbac) — hard-coded in modules/aks-cluster, but
  # surfaced here for the aad_profile block.
  fleet_aks = try(var.doc.fleet.aad.aks, {})
  # Env-scope AKS config (admin_groups, rbac_cluster_admins, rbac_readers).
  env_aks = try(var.doc.fleet.environments[local.cluster.env].aks, {})
  # Per-cluster AKS passthrough (curated typed) — see
  # modules/aks-cluster/variables.tf for the contract. Absent in most
  # cluster.yaml files; everything has a sensible default in the module.
  aks_override = try(var.doc.cluster.aks, {})

  # Preconditions fire against these via a terraform_data null resource.
  # Keeping the check list local so the error message can name the
  # exact yaml path that failed.
  required_networking = {
    subnet_slot         = local.net.subnet_slot
    snet_aks_api_cidr   = try(local.net.snet_aks_api_cidr, null)
    snet_aks_nodes_cidr = try(local.net.snet_aks_nodes_cidr, null)
    env_region_vnet_id  = var.env_region_vnet_resource_id
    mgmt_vnet_id        = var.mgmt_vnet_resource_id
    node_asg_id         = var.node_asg_resource_id
  }
}

# Early fail-fast for the networking contract. Every downstream resource
# in this stack assumes these are set; surfacing null here with the yaml
# path beats a downstream azapi error that names only a resource id.
resource "terraform_data" "network_preconditions" {
  lifecycle {
    precondition {
      condition     = local.required_networking.subnet_slot != null
      error_message = "cluster.yaml is missing required field networking.subnet_slot (PLAN §3.4)."
    }
    precondition {
      condition     = local.required_networking.snet_aks_api_cidr != null && local.required_networking.snet_aks_nodes_cidr != null
      error_message = "config-loader did not emit derived.networking.snet_aks_{api,nodes}_cidr. Check _fleet.yaml.networking.envs.<env>.regions.<region>.address_space is set (PLAN §3.4)."
    }
    precondition {
      condition     = local.required_networking.env_region_vnet_id != null && can(regex("^/subscriptions/[0-9a-fA-F-]{36}/resourceGroups/[^/]+/providers/Microsoft\\.Network/virtualNetworks/[^/]+$", local.required_networking.env_region_vnet_id))
      error_message = "TF_VAR_env_region_vnet_resource_id must be a full VNet ARM id. Published by bootstrap/environment as <ENV>_<REGION>_VNET_RESOURCE_ID."
    }
    precondition {
      condition     = local.required_networking.mgmt_vnet_id != null && can(regex("^/subscriptions/[0-9a-fA-F-]{36}/resourceGroups/[^/]+/providers/Microsoft\\.Network/virtualNetworks/[^/]+$", local.required_networking.mgmt_vnet_id))
      error_message = "TF_VAR_mgmt_vnet_resource_id must be a full VNet ARM id. Published by bootstrap/fleet as MGMT_VNET_RESOURCE_ID."
    }
    precondition {
      condition     = local.required_networking.node_asg_id != null && can(regex("^/subscriptions/[0-9a-fA-F-]{36}/resourceGroups/[^/]+/providers/Microsoft\\.Network/applicationSecurityGroups/[^/]+$", local.required_networking.node_asg_id))
      error_message = "TF_VAR_node_asg_resource_id must be a full ASG ARM id. Published by bootstrap/environment as <ENV>_<REGION>_NODE_ASG_RESOURCE_ID."
    }
  }
}
