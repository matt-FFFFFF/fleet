# stages/1-cluster/main.identities.tf
#
# Per-cluster user-assigned managed identities (PLAN §4 Stage 1 lines
# 1785-1794):
#
#   uami-external-dns-<cluster>       — reconciles records in the cluster's
#                                       own private DNS zone
#   uami-eso-<cluster>                — External Secrets Operator pull source
#                                       (cluster KV + fleet KV)
#   uami-team-<team>-<cluster>        — one per team opted into this cluster
#                                       (cluster.yaml `teams:` list)
#   uami-argocd-spoke-<cluster>       — spoke clusters only (gated on
#                                       cluster.role != "management"); the
#                                       identity that mgmt's central Argo
#                                       assumes when it talks to this
#                                       cluster's K8s API. Carries
#                                       AKS RBAC Cluster Admin on this AKS
#                                       (main.rbac.tf) and three FICs back
#                                       to the mgmt cluster's OIDC issuer
#                                       (this file).
#
# FICs on the **per-workload** UAMIs (external-dns, ESO, team-<team>) are
# created in Stage 2 — they need this cluster's own AKS OIDC issuer URL,
# which is a Stage 1 output. The Argo-spoke FICs above use the **mgmt**
# cluster's OIDC issuer (a fleet-wide repo var), so they have no Stage-1
# data dependency and live here.
#
# The **cluster control-plane UAMI** (`uami-<cluster>-cp`) lives inside
# `modules/aks-cluster` — it's the identity the AVM module attaches to
# the managed cluster, not a workload identity. The **kubelet identity**
# stays AKS-managed (surfaced by the AVM module) and is only referenced
# by main.rbac.tf for the AcrPull assignment. The **Kargo mgmt UAMI**
# is a fleet-wide singleton authored by Stage 0; its principalId
# arrives here as `var.kargo_mgmt_uami_principal_id` for the RBAC
# Reader assignment on the mgmt cluster's AKS resource (mgmt-only post
# hub-and-spoke).

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

# --- Argo spoke UAMI (workload clusters only) -------------------------------
#
# PLAN §1 hub-and-spoke: the central Argo on mgmt authenticates inbound to
# this cluster's K8s API by assuming `uami-argocd-spoke-<cluster>`, which
# carries `Azure Kubernetes Service RBAC Cluster Admin` on this cluster's
# own AKS resource (see main.rbac.tf). On mgmt itself, Argo runs locally
# and uses its own in-cluster ServiceAccount token — no spoke UAMI
# needed.
#
# The three FICs below bind this UAMI to the three Argo controller SAs on
# the **mgmt** cluster's OIDC issuer. Issuer is a fleet-wide repo var
# (`MGMT_AKS_OIDC_ISSUER_URL`, published by mgmt's Stage 1 — see PLAN §4
# Stage 1 outputs); subjects/audience are constants. Because no Stage 1
# output of *this* cluster is used in the FIC body, the FICs can land in
# Stage 1 instead of Stage 2 (no kubernetes/helm provider dependency).

resource "azapi_resource" "uami_argocd_spoke" {
  count = local.mgmt_role_cluster ? 0 : 1

  type      = "Microsoft.ManagedIdentity/userAssignedIdentities@2023-01-31"
  name      = "uami-argocd-spoke-${local.cluster.name}"
  parent_id = local.identity_parent_id
  location  = local.cluster.region

  body = {}

  response_export_values = ["id", "properties.principalId", "properties.clientId"]

  tags = local.identity_tags
}

locals {
  # Three Argo controller SAs on the mgmt cluster that must be able to
  # exchange their projected SA tokens for an AAD access token whose
  # `client_id` is this spoke's UAMI. Azure caps `subjects` at one per
  # FIC, so we author three FICs.
  argocd_spoke_subjects = local.mgmt_role_cluster ? [] : [
    "system:serviceaccount:argocd:argocd-application-controller",
    "system:serviceaccount:argocd:argocd-applicationset-controller",
    "system:serviceaccount:argocd:argocd-server",
  ]
}

resource "azapi_resource" "fc_argocd_spoke" {
  for_each = toset(local.argocd_spoke_subjects)

  type      = "Microsoft.ManagedIdentity/userAssignedIdentities/federatedIdentityCredentials@2023-01-31"
  parent_id = azapi_resource.uami_argocd_spoke[0].id
  # Stable, deterministic FIC name per subject. Trailing token is the
  # SA name (last `:`-segment of the subject) — keeps the resource
  # name human-readable in the portal.
  name = "fc-argocd-spoke-${reverse(split(":", each.key))[0]}"

  body = {
    properties = {
      issuer    = var.mgmt_aks_oidc_issuer_url
      subject   = each.key
      audiences = ["api://AzureADTokenExchange"]
    }
  }

  response_export_values = []

  lifecycle {
    precondition {
      condition     = var.mgmt_aks_oidc_issuer_url != null && length(var.mgmt_aks_oidc_issuer_url) > 0
      error_message = "mgmt_aks_oidc_issuer_url is required on spoke clusters (cluster.role != \"management\"). Publish it as the MGMT_AKS_OIDC_ISSUER_URL repo variable from the mgmt cluster's Stage 1 outputs (see PLAN §4 Stage 1 outputs) and wire it into TF_VAR_mgmt_aks_oidc_issuer_url in tf-apply.yaml. While stage0-publisher GH App is gated `if: false`, the operator populates this var manually after the first mgmt apply."
    }
  }
}
