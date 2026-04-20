# stages/1-cluster/main.aks.tf
#
# AKS cluster + per-cluster private DNS zone. See PLAN §4 Stage 1 for
# the full surface; Phase E (this commit) delivers the *networking*
# slice — everything else (cluster KV, UAMIs, role assignments,
# managed Prometheus DCR/DCRA/rules, Kargo mgmt rotation) is tracked
# as TODO in STATUS §4 Stage 1 and lands when Stage 1 is promoted out
# of Phase E.
#
# Hard-coded in modules/aks-cluster, NOT overridable per cluster:
#   - Entra-only auth: disable_local_accounts + aad_profile.managed +
#     enable_azure_rbac (tenant_id + admin_groups from _fleet.yaml).
#   - CNI: Azure CNI Overlay + Cilium dataplane, pod_cidr from the
#     loader-derived CGNAT allocation (PLAN §3.4).
#   - OIDC issuer + workload identity on (Stage 2 FICs depend on it).
#   - Private cluster with API-server VNet integration on the
#     /28 subnet this stack creates.
#
# Operator-tunable via `cluster.aks.*` (curated typed passthrough —
# see modules/aks-cluster/variables.tf for the contract):
#   kubernetes_version, sku_tier, auto_upgrade_profile,
#   auto_scaler_profile.

module "aks" {
  source = "../../modules/aks-cluster"

  cluster_name = local.cluster.name
  location     = local.cluster.region
  parent_id    = "/subscriptions/${local.cluster.subscription_id}/resourceGroups/${local.cluster.resource_group}"

  # Networking inputs — all loader-derived or passed from bootstrap.
  api_subnet_id  = local.cluster_subnet_ids.api
  node_subnet_id = local.cluster_subnet_ids.nodes
  pod_cidr       = local.net.pod_cidr
  node_asg_ids   = [var.node_asg_resource_id]

  # AAD / RBAC — sourced from _fleet.yaml (aad.aks tenant + env-scope
  # admin_groups). The module hard-codes managed + disable_local + rbac.
  aad = {
    tenant_id              = try(local.fleet_aks.tenant_id, local.fleet.tenant_id)
    admin_group_object_ids = try(local.env_aks.admin_groups, [])
  }

  # Cluster version / SKU / upgrade / autoscaler — kubernetes.* comes
  # from the `_defaults.yaml` chain (overridable per cluster); aks_override
  # is the curated cluster.aks passthrough.
  kubernetes_version  = try(local.aks_override.kubernetes_version, local.kubernetes.version, null)
  sku_tier            = try(local.aks_override.sku_tier, local.kubernetes.sku_tier, "Standard")
  auto_scaler_profile = try(local.aks_override.auto_scaler_profile, local.kubernetes.cluster_autoscaler_profile, null)
  auto_upgrade_profile = try(local.aks_override.auto_upgrade_profile, {
    upgrade_channel         = try(local.kubernetes.control_plane_upgrade, "patch")
    node_os_upgrade_channel = try(local.kubernetes.node_image_upgrade, "NodeImage")
  })

  # Node pool sizing — from _defaults.yaml.node_pools.{system,apps}.
  # apps pool is optional (some clusters may ship system-only).
  system_pool = try(var.doc.node_pools.system, {})
  apps_pool   = try(var.doc.node_pools.apps, null)

  tags = {
    fleet       = local.fleet.name
    environment = local.cluster.env
    region      = local.cluster.region
    cluster     = local.cluster.name
    role        = try(local.cluster.role, "workload")
    stage       = "1-cluster"
  }

  depends_on = [
    azapi_resource.snet_aks_api,
    azapi_resource.snet_aks_nodes,
  ]
}

# --- Per-cluster private DNS zone -------------------------------------------
#
# Zone at `<dns.zone_fqdn>` (derived per §3.3), linked to exactly the env
# VNet + the mgmt VNet. External-dns in this cluster is scoped to this
# zone via `--domain-filter` (platform-gitops side); RBAC writes land
# in Stage 2 once UAMIs exist. Zone + links are authored here because
# they're per-cluster lifecycle; role assignments deferred to the
# identity/RBAC phase (STATUS §4 Stage 1 TODO).

module "cluster_dns" {
  source = "../../modules/cluster-dns"

  zone_fqdn      = local.derived.dns_zone_fqdn
  parent_id      = "/subscriptions/${local.cluster.subscription_id}/resourceGroups/${local.derived.dns_zone_resource_group}"
  linked_vnet_ids = {
    env  = var.env_region_vnet_resource_id
    mgmt = var.mgmt_vnet_resource_id
  }

  tags = {
    fleet       = local.fleet.name
    environment = local.cluster.env
    cluster     = local.cluster.name
    stage       = "1-cluster"
  }
}
