# stages/1-cluster
#
# Per-cluster TF stack, one apply per cluster, driven by
# `config-loader/load.sh <clusters/<env>/<region>/<name>>` → merged
# tfvars.json. See PLAN §4 Stage 1.
#
# **Layout** (files in this directory):
#
#   main.tf           : locals, network preconditions (this file)
#   main.network.tf   : per-cluster /28 api + /25 nodes subnets as
#                       children of the env VNet
#   main.aks.tf       : AKS cluster (via modules/aks-cluster) + per-cluster
#                       private DNS zone (via modules/cluster-dns)
#   main.kv.tf        : cluster Key Vault + mgmt-only Kargo OIDC secret
#                       rotation (azuread_application_password + time_rotating
#                       + KV secret writes)
#   main.identities.tf: per-cluster UAMIs (external-dns, ESO, team-<team>)
#   main.rbac.tf      : role assignments on every scope this stage touches
#                       (cluster KV, fleet KV, fleet ACR, this AKS resource,
#                       the per-cluster private DNS zone, the env AMW)
#   main.monitoring.tf: managed Prometheus DCR/DCRA + recording rule groups
#                       (gated on `platform.observability.managed_prometheus.enabled`)
#
# Hard-coded in modules/aks-cluster (NOT overridable per cluster):
# Entra-only auth (`disable_local_accounts` + `aad_profile.managed` +
# `enable_azure_rbac`), CNI Overlay + Cilium, private cluster with
# API-server VNet integration on the /28 subnet this stack creates,
# OIDC issuer + workload identity on, pod CIDR 100.64.0.0/16,
# service CIDR 100.127.0.0/16.
#
# Inputs arrive via the loader-produced tfvars.json; no provider data
# sources at plan time (PLAN §10). Cross-stage values
# (`MGMT_VNET_RESOURCE_IDS` JSON map on `fleet-meta`,
# `<ENV>_<REGION>_{VNET,NODE_ASG,ROUTE_TABLE}_RESOURCE_ID` on the
# per-env GH Environment, fleet-scope ids like `FLEET_KEYVAULT_ID` /
# `ACR_RESOURCE_ID` / `KARGO_*` from Stage 0) flow in as repo/env
# variables (TF_VAR_*) — Stage 0 does **not** proxy the env-scope
# values (see PLAN §4 Stage -1 "Implementation status 2026-04-19" for
# the cycle-break rationale). `tf-apply.yaml` resolves the cluster's
# mgmt peer region (`derived.networking.peer_mgmt_region`,
# same-region-else-first from `networking.envs.mgmt.regions.*`) and
# indexes the JSON map to set `TF_VAR_mgmt_region_vnet_resource_id`
# per cluster.

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
  env_aks = try(var.doc.fleet.envs[local.cluster.env].aks, {})
  # Per-cluster AKS passthrough (curated typed) — see
  # modules/aks-cluster/variables.tf for the contract. Absent in most
  # cluster.yaml files; everything has a sensible default in the module.
  aks_override = try(var.doc.cluster.aks, {})

  # Mgmt clusters share the mgmt VNet directly — the env-region VNet
  # *is* the mgmt VNet. Detected by comparing the two ids rather than
  # by `cluster.env == "mgmt"` so the collapse is schema-driven (and
  # would still fire if a future schema change allowed non-mgmt envs
  # to share the mgmt VNet).
  mgmt_cluster = var.env_region_vnet_resource_id == var.mgmt_region_vnet_resource_id

  # Management-cluster detection for Kargo-specific secret rotation
  # (PLAN §4 Stage 1 lines 1769-1784). Driven by a cluster-yaml opt-in
  # (`cluster.role == "management"`) rather than the VNet-collapse
  # heuristic above, because role is the operator-intent signal: a
  # mgmt-env cluster that isn't marked role=management should NOT
  # host the Kargo control plane. Default "workload" keeps the
  # rotation resources dormant on every other cluster.
  mgmt_role_cluster = try(local.cluster.role, "workload") == "management"

  # Managed Prometheus enablement — default ON per PLAN §4 Stage 1. The
  # per-cluster opt-out lives at `platform.observability.managed_prometheus.enabled`
  # (documented in PLAN §4.1). Drives both the AVM module input
  # (`azureMonitorProfile.metrics.enabled`) and whether
  # modules/cluster-monitoring is instantiated.
  managed_prometheus_enabled = try(
    var.doc.platform.observability.managed_prometheus.enabled, true
  )

  # Preconditions fire against these via a terraform_data null resource.
  # Keeping the check list local so the error message can name the
  # exact yaml path that failed.
  required_networking = {
    subnet_slot         = local.net.subnet_slot
    snet_aks_api_cidr   = try(local.net.snet_aks_api_cidr, null)
    snet_aks_nodes_cidr = try(local.net.snet_aks_nodes_cidr, null)
    env_region_vnet_id  = var.env_region_vnet_resource_id
    mgmt_vnet_id        = var.mgmt_region_vnet_resource_id
    node_asg_id         = var.node_asg_resource_id
    route_table_id      = var.route_table_resource_id
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
      error_message = "TF_VAR_mgmt_region_vnet_resource_id must be a full VNet ARM id. Selected per-cluster from fromJSON(vars.MGMT_VNET_RESOURCE_IDS)[derived.networking.peer_mgmt_region] (published by bootstrap/fleet on the fleet-meta GH Environment)."
    }
    precondition {
      condition     = local.required_networking.node_asg_id != null && can(regex("^/subscriptions/[0-9a-fA-F-]{36}/resourceGroups/[^/]+/providers/Microsoft\\.Network/applicationSecurityGroups/[^/]+$", local.required_networking.node_asg_id))
      error_message = "TF_VAR_node_asg_resource_id must be a full ASG ARM id. Published by bootstrap/environment as <ENV>_<REGION>_NODE_ASG_RESOURCE_ID."
    }
    precondition {
      condition     = local.required_networking.route_table_id != null && can(regex("^/subscriptions/[0-9a-fA-F-]{36}/resourceGroups/[^/]+/providers/Microsoft\\.Network/routeTables/[^/]+$", local.required_networking.route_table_id))
      error_message = "TF_VAR_route_table_resource_id must be a full route table ARM id. Published by bootstrap/environment as <ENV>_<REGION>_ROUTE_TABLE_RESOURCE_ID. The route table shell is authored unconditionally; for live apply, networking.envs.<env>.regions.<region>.egress_next_hop_ip must also be set so the 0.0.0.0/0 route entry exists (PLAN §3.4 UDR egress)."
    }
  }
}
