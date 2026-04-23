# stages/1-cluster/main.monitoring.tf
#
# Managed Prometheus wiring for this cluster (PLAN §4 Stage 1 lines
# 1854-1878). Gated on
# `platform.observability.managed_prometheus.enabled` (default true) —
# see `local.managed_prometheus_enabled` in main.tf. When disabled,
# the AVM AKS module's `azureMonitorProfile.metrics.enabled` is also
# flipped off (via main.aks.tf) and the `Monitoring Metrics Publisher`
# role assignment in main.rbac.tf is skipped.
#
# The module authors:
#   - DCR (`dcr-prom-<cluster>`)    → env AMW via env DCE
#   - DCRA (`dcr-<cluster>`)         → binds the DCR to the AKS cluster
#   - DCEA (`configurationAccessEndpoint`) → binds the env DCE to the
#                                     AKS cluster (addon endpoint lookup)
#   - Three Prometheus recording rule groups (node/k8s/UX) scoped to
#     the env AMW
#
# The env DCE + env AMW are owned by `bootstrap/environment` (ids arrive
# as `TF_VAR_env_*`). The env Action Group id is still published by
# `bootstrap/environment` and passed through Stage 1's outputs for
# downstream alerting consumers, but it is not consumed by this module
# — ruleGroups here ship recording rules only.

module "cluster_monitoring" {
  source = "../../modules/cluster-monitoring"

  count = local.managed_prometheus_enabled ? 1 : 0

  cluster_name   = local.cluster.name
  aks_cluster_id = module.aks.resource_id
  location       = local.cluster.region
  parent_id      = "/subscriptions/${local.cluster.subscription_id}/resourceGroups/${local.cluster.resource_group}"

  dce_id = var.env_dce_id
  amw_id = var.env_monitor_workspace_id

  tags = {
    fleet       = local.fleet.name
    environment = local.cluster.env
    region      = local.cluster.region
    cluster     = local.cluster.name
    stage       = "1-cluster"
  }
}
