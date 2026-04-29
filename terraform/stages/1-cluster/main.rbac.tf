# stages/1-cluster/main.rbac.tf
#
# Every role assignment this stage authors (PLAN §4 Stage 1 lines
# 1798-1853). All use `azapi_resource` on
# `Microsoft.Authorization/roleAssignments` with a deterministic
# `name` (a UUIDv5 of scope + principalId + role) so re-applies are
# idempotent without a plan-time data source. Each block carries a
# one-liner naming the consumer.
#
# Built-in role definition GUIDs
# (https://learn.microsoft.com/azure/role-based-access-control/built-in-roles):
#
#   Private DNS Zone Contributor          b12aa53e-6015-4669-85d0-8515ebb3ae7f
#   Key Vault Secrets User                4633458b-17de-408a-b874-0445c86b69e6
#   AcrPull                               7f951dda-4ed3-4680-a7ca-43fe172d538d
#   AKS RBAC Cluster Admin                b1ff04bb-8a4e-4dc4-8eb5-8693973ce19b
#   AKS RBAC Reader                       7f6c6a51-bcf8-42ba-9220-52d62157d7db
#   AKS Cluster User Role                 4abbcc35-e782-43d8-92c5-2d3f1bd2253f
#   Monitoring Metrics Publisher          3913510d-42f4-6e8d-76ca-c8e3c6c6e5b7

locals {
  role_private_dns_zone_contrib = "b12aa53e-6015-4669-85d0-8515ebb3ae7f"
  role_kv_secrets_user          = "4633458b-17de-408a-b874-0445c86b69e6"
  role_acr_pull                 = "7f951dda-4ed3-4680-a7ca-43fe172d538d"
  role_aks_rbac_cluster_admin   = "b1ff04bb-8a4e-4dc4-8eb5-8693973ce19b"
  role_aks_rbac_reader          = "7f6c6a51-bcf8-42ba-9220-52d62157d7db"
  role_aks_cluster_user         = "4abbcc35-e782-43d8-92c5-2d3f1bd2253f"
  role_monitoring_metrics_pub   = "3913510d-42f4-6e8d-76ca-c8e3c6c6e5b7"

  # Unioned group list for the `AKS Cluster User Role` assignment
  # (human `az aks get-credentials` path). Distinct() handles the
  # common case where an operator appears in both lists by mistake.
  aks_human_groups = distinct(concat(
    try(local.env_aks.rbac_cluster_admins, []),
    try(local.env_aks.rbac_readers, []),
  ))

  # Scope the cluster subscription uses for the
  # `Microsoft.Authorization/roleDefinitions/<guid>` lookups. All role
  # definitions are built-in (stable across subs) so which sub we
  # address the definition through is cosmetic; using the cluster sub
  # keeps the definition id on the same sub as the scope.
  role_def_sub = local.cluster.subscription_id
}

# Helper: role-definition ARM id for a guid, on this cluster's sub.
locals {
  role_def_base = "/subscriptions/${local.role_def_sub}/providers/Microsoft.Authorization/roleDefinitions"

  role_def_ids = {
    pdz_contrib    = "${local.role_def_base}/${local.role_private_dns_zone_contrib}"
    kv_secrets_usr = "${local.role_def_base}/${local.role_kv_secrets_user}"
    acr_pull       = "${local.role_def_base}/${local.role_acr_pull}"
    aks_admin      = "${local.role_def_base}/${local.role_aks_rbac_cluster_admin}"
    aks_reader     = "${local.role_def_base}/${local.role_aks_rbac_reader}"
    aks_user       = "${local.role_def_base}/${local.role_aks_cluster_user}"
    monitor_pub    = "${local.role_def_base}/${local.role_monitoring_metrics_pub}"
  }
}

# --- External-DNS UAMI → Private DNS Zone Contributor on cluster zone ------

resource "azapi_resource" "ra_extdns_pdz" {
  type      = "Microsoft.Authorization/roleAssignments@2022-04-01"
  name      = uuidv5("url", "pdz-contrib|${module.cluster_dns.zone_resource_id}|${azapi_resource.uami_external_dns.output.properties.principalId}")
  parent_id = module.cluster_dns.zone_resource_id

  body = {
    properties = {
      principalId      = azapi_resource.uami_external_dns.output.properties.principalId
      principalType    = "ServicePrincipal"
      roleDefinitionId = local.role_def_ids.pdz_contrib
    }
  }
}

# --- ESO UAMI → KV Secrets User on cluster KV + fleet KV -------------------

resource "azapi_resource" "ra_eso_cluster_kv" {
  type      = "Microsoft.Authorization/roleAssignments@2022-04-01"
  name      = uuidv5("url", "kv-secrets-user|${module.cluster_kv.resource_id}|${azapi_resource.uami_eso.output.properties.principalId}")
  parent_id = module.cluster_kv.resource_id

  body = {
    properties = {
      principalId      = azapi_resource.uami_eso.output.properties.principalId
      principalType    = "ServicePrincipal"
      roleDefinitionId = local.role_def_ids.kv_secrets_usr
    }
  }
}

resource "azapi_resource" "ra_eso_fleet_kv" {
  type      = "Microsoft.Authorization/roleAssignments@2022-04-01"
  name      = uuidv5("url", "kv-secrets-user|${var.fleet_keyvault_id}|${azapi_resource.uami_eso.output.properties.principalId}")
  parent_id = var.fleet_keyvault_id

  body = {
    properties = {
      principalId      = azapi_resource.uami_eso.output.properties.principalId
      principalType    = "ServicePrincipal"
      roleDefinitionId = local.role_def_ids.kv_secrets_usr
    }
  }
}

# --- Kubelet identity → AcrPull on fleet ACR -------------------------------
#
# The kubelet identity is AKS-managed (surfaced by the AVM module's
# `kubelet_identity` output). We use the `object_id` field as the
# role-assignment `principalId`.

resource "azapi_resource" "ra_kubelet_acrpull" {
  type      = "Microsoft.Authorization/roleAssignments@2022-04-01"
  name      = uuidv5("url", "acr-pull|${var.acr_resource_id}|${module.aks.kubelet_identity.object_id}")
  parent_id = var.acr_resource_id

  body = {
    properties = {
      principalId      = module.aks.kubelet_identity.object_id
      principalType    = "ServicePrincipal"
      roleDefinitionId = local.role_def_ids.acr_pull
    }
  }
}

# --- fleet-<env> UAMI → AKS RBAC Cluster Admin on this AKS resource --------
#
# Required because `disable_local_accounts=true`: Stage 2 (running under
# the same `uami-fleet-<env>` identity) must authenticate to the K8s
# API via an AAD bearer token, and needs cluster-admin to create
# namespaces + install Helm releases + bootstrap ArgoCD.

resource "azapi_resource" "ra_fleet_env_aks_admin" {
  type      = "Microsoft.Authorization/roleAssignments@2022-04-01"
  name      = uuidv5("url", "aks-admin|${module.aks.resource_id}|${var.fleet_env_uami_principal_id}")
  parent_id = module.aks.resource_id

  body = {
    properties = {
      principalId      = var.fleet_env_uami_principal_id
      principalType    = "ServicePrincipal"
      roleDefinitionId = local.role_def_ids.aks_admin
    }
  }
}

# --- Human groups → AKS RBAC Cluster Admin / Reader on this AKS resource ---
#
# Groups are AAD object ids listed in
# `envs.<env>.aks.{rbac_cluster_admins,rbac_readers}` (already object
# ids in `_fleet.yaml` — no `azuread_group` data source needed).

resource "azapi_resource" "ra_aks_admin_groups" {
  for_each = toset(try(local.env_aks.rbac_cluster_admins, []))

  type      = "Microsoft.Authorization/roleAssignments@2022-04-01"
  name      = uuidv5("url", "aks-admin|${module.aks.resource_id}|${each.key}")
  parent_id = module.aks.resource_id

  body = {
    properties = {
      principalId      = each.key
      principalType    = "Group"
      roleDefinitionId = local.role_def_ids.aks_admin
    }
  }
}

resource "azapi_resource" "ra_aks_reader_groups" {
  for_each = toset(try(local.env_aks.rbac_readers, []))

  type      = "Microsoft.Authorization/roleAssignments@2022-04-01"
  name      = uuidv5("url", "aks-reader|${module.aks.resource_id}|${each.key}")
  parent_id = module.aks.resource_id

  body = {
    properties = {
      principalId      = each.key
      principalType    = "Group"
      roleDefinitionId = local.role_def_ids.aks_reader
    }
  }
}

# --- Human groups → AKS Cluster User Role ---------------------------------
#
# Required by `az aks get-credentials` (the human workflow) to fetch the
# AAD-auth kubeconfig stub. CI does NOT need this role — Stage 2 builds
# its provider auth directly from Stage 1 outputs (host + CA + AAD
# bearer token) and never calls `listClusterUserCredential`.

resource "azapi_resource" "ra_aks_user_groups" {
  for_each = toset(local.aks_human_groups)

  type      = "Microsoft.Authorization/roleAssignments@2022-04-01"
  name      = uuidv5("url", "aks-user|${module.aks.resource_id}|${each.key}")
  parent_id = module.aks.resource_id

  body = {
    properties = {
      principalId      = each.key
      principalType    = "Group"
      roleDefinitionId = local.role_def_ids.aks_user
    }
  }
}

# --- Argo spoke UAMI → AKS RBAC Cluster Admin on this AKS (spokes only) ----
#
# The per-spoke `uami-argocd-spoke-<cluster>` (main.identities.tf) is the
# identity mgmt's central Argo assumes when reconciling against this
# cluster's K8s API (PLAN §1 hub-and-spoke). Argo creates/deletes
# arbitrary resources fleet-wide, so the spoke side must grant it
# cluster-admin. Scope is this AKS resource only — Argo cannot reach any
# other Azure resource through this UAMI.
# Skipped on the mgmt cluster: Argo's local `argocd-application-controller`
# SA talks to `kubernetes.default.svc` directly, no AAD round-trip.

resource "azapi_resource" "ra_argocd_spoke_aks_admin" {
  count = local.mgmt_role_cluster ? 0 : 1

  type      = "Microsoft.Authorization/roleAssignments@2022-04-01"
  name      = uuidv5("url", "aks-admin|${module.aks.resource_id}|${azapi_resource.uami_argocd_spoke[0].output.properties.principalId}")
  parent_id = module.aks.resource_id

  body = {
    properties = {
      principalId      = azapi_resource.uami_argocd_spoke[0].output.properties.principalId
      principalType    = "ServicePrincipal"
      roleDefinitionId = local.role_def_ids.aks_admin
    }
  }
}

# --- Kargo mgmt UAMI → AKS RBAC Reader on the mgmt AKS --------------------
#
# Under PLAN §1 hub-and-spoke, the central Argo on mgmt is the only
# Argo instance, so every Argo `Application` CR exists on mgmt's K8s
# API. Kargo (also mgmt-resident) reads those CRs for health-check /
# promotion gating; it therefore only needs `AKS RBAC Reader` on the
# **mgmt** cluster. Spoke clusters host no Argo CRs and require no
# Kargo grant.

resource "azapi_resource" "ra_kargo_aks_reader" {
  count = local.mgmt_role_cluster ? 1 : 0

  type      = "Microsoft.Authorization/roleAssignments@2022-04-01"
  name      = uuidv5("url", "aks-reader|${module.aks.resource_id}|${var.kargo_mgmt_uami_principal_id}")
  parent_id = module.aks.resource_id

  body = {
    properties = {
      principalId      = var.kargo_mgmt_uami_principal_id
      principalType    = "ServicePrincipal"
      roleDefinitionId = local.role_def_ids.aks_reader
    }
  }
}

# --- Cluster UAMI → Monitoring Metrics Publisher on env AMW ----------------
#
# When `azureMonitorProfile.metrics.enabled=true`, the AKS
# managed-prometheus addon authenticates to the AMW ingestion endpoint
# using the cluster's attached UAMI (the `uami-<cluster>-cp` authored
# inside `modules/aks-cluster`). Scoping the role on the env AMW
# ensures a cluster can push metrics ONLY to its own env's workspace —
# prod clusters cannot write nonprod metrics (PLAN §4 Stage 1 lines
# 1846-1853). Assignment is skipped when managed-prometheus is
# disabled per cluster opt-out.

resource "azapi_resource" "ra_cluster_monitor_pub" {
  count = local.managed_prometheus_enabled ? 1 : 0

  type      = "Microsoft.Authorization/roleAssignments@2022-04-01"
  name      = uuidv5("url", "monitor-pub|${var.env_monitor_workspace_id}|${module.aks.cluster_identity.principal_id}")
  parent_id = var.env_monitor_workspace_id

  body = {
    properties = {
      principalId      = module.aks.cluster_identity.principal_id
      principalType    = "ServicePrincipal"
      roleDefinitionId = local.role_def_ids.monitor_pub
    }
  }
}
