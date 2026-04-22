# stages/1-cluster/main.identities.tf
#
# Per-cluster user-assigned managed identities (PLAN §4 Stage 1 lines
# 1785-1794). Three fixed + one per team:
#
#   uami-external-dns-<cluster>  — reconciles records in the cluster's
#                                   own private DNS zone
#   uami-eso-<cluster>           — External Secrets Operator pull source
#                                   (cluster KV + fleet KV)
#   uami-team-<team>-<cluster>   — one per team opted into this cluster
#                                   (cluster.yaml `teams:` list)
#
# Federated Identity Credentials (FICs) on each of these are created in
# Stage 2 — they need the AKS OIDC issuer URL as the FIC `issuer`, and
# keeping the FIC author with its consumer (the k8s SA annotation) in
# the same stage is what PLAN §4 Stage 1 specifies (line 1795-1797).
#
# The **cluster control-plane UAMI** (`uami-<cluster>-cp`) lives inside
# `modules/aks-cluster` — it's the identity the AVM module attaches to
# the managed cluster, not a workload identity. The **kubelet identity**
# stays AKS-managed (surfaced by the AVM module) and is only referenced
# by main.rbac.tf for the AcrPull assignment. The **Kargo mgmt UAMI**
# is a fleet-wide singleton authored by Stage 0; its principalId
# arrives here as `var.kargo_mgmt_uami_principal_id` for the RBAC
# Reader assignment on every workload cluster's AKS resource.

locals {
  # Teams opted into this cluster. `cluster.yaml.teams` is a list of
  # team names (strings); each name is the basename of the matching
  # `platform-gitops/config/teams/<team>.yaml`. Silence-on-absence —
  # an absent or empty list yields zero per-team UAMIs.
  cluster_teams = try(local.cluster.teams, [])

  identity_parent_id = "/subscriptions/${local.cluster.subscription_id}/resourceGroups/${local.cluster.resource_group}"

  identity_tags = {
    fleet       = local.fleet.name
    environment = local.cluster.env
    region      = local.cluster.region
    cluster     = local.cluster.name
    stage       = "1-cluster"
  }
}

resource "azapi_resource" "uami_external_dns" {
  type      = "Microsoft.ManagedIdentity/userAssignedIdentities@2023-01-31"
  name      = "uami-external-dns-${local.cluster.name}"
  parent_id = local.identity_parent_id
  location  = local.cluster.region

  body = {}

  response_export_values = ["id", "properties.principalId", "properties.clientId"]

  tags = local.identity_tags
}

resource "azapi_resource" "uami_eso" {
  type      = "Microsoft.ManagedIdentity/userAssignedIdentities@2023-01-31"
  name      = "uami-eso-${local.cluster.name}"
  parent_id = local.identity_parent_id
  location  = local.cluster.region

  body = {}

  response_export_values = ["id", "properties.principalId", "properties.clientId"]

  tags = local.identity_tags
}

resource "azapi_resource" "uami_team" {
  for_each = toset(local.cluster_teams)

  type      = "Microsoft.ManagedIdentity/userAssignedIdentities@2023-01-31"
  name      = "uami-team-${each.key}-${local.cluster.name}"
  parent_id = local.identity_parent_id
  location  = local.cluster.region

  body = {}

  response_export_values = ["id", "properties.principalId", "properties.clientId"]

  tags = merge(local.identity_tags, { team = each.key })
}
