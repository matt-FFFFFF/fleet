# modules/aks-cluster/main.tf
#
# Thin wrapper around `Azure/avm-res-containerservice-managedcluster/azurerm`
# (azapi-based AVM module; keeps the repo provider-set invariant).
#
# Scope today (Phase E of PLAN §3.4) is the *networking* slice of
# Stage 1: private cluster + api-server VNet integration on the /28
# subnet, agent pools attached to the env-region ASG, Azure CNI
# Overlay + Cilium with a CGNAT pod_cidr. Everything else (cluster
# KV, UAMIs, role assignments, managed Prometheus DCR/DCRA + rules,
# Kargo mgmt rotation) is deferred — see STATUS §4 Stage 1 TODOs and
# PLAN §4 Stage 1 for the full surface.
#
# Hard-coded policy (NOT overridable per cluster — see variables.tf
# header for the full list): Entra-only auth, OIDC issuer on, workload
# identity on, CNI Overlay + Cilium, private cluster with VNet
# integration, user-assigned managed identity (created here).

# --- User-assigned managed identity for the cluster -------------------------
#
# Kubelet identity stays the AKS-managed default (needed for AcrPull
# role assignment in the identity/RBAC phase); the *cluster* identity
# is a fleet-owned UAMI so its principal id is stable and referenceable
# across stage boundaries without an Azure data-source call. Name
# mirrors the PLAN §3.3 convention `uami-<cluster>-<purpose>`.

resource "azapi_resource" "cluster_uami" {
  type      = "Microsoft.ManagedIdentity/userAssignedIdentities@2023-01-31"
  name      = "uami-aks-${var.cluster_name}"
  parent_id = var.parent_id
  location  = var.location

  body = {}

  response_export_values = ["id", "properties.principalId", "properties.clientId"]

  tags = var.tags
}

# --- Managed cluster --------------------------------------------------------

module "aks" {
  source  = "Azure/avm-res-containerservice-managedcluster/azurerm"
  version = "~> 0.5"

  enable_telemetry = false

  name      = var.cluster_name
  location  = var.location
  parent_id = var.parent_id
  tags      = var.tags

  kubernetes_version = var.kubernetes_version

  sku = {
    name = "Base"
    tier = var.sku_tier
  }

  # DNS prefix for the private cluster. Derived from the cluster name
  # (AKS requires [a-z0-9-]{1,54}); truncate defensively.
  dns_prefix = substr(var.cluster_name, 0, 54)

  # --- Private cluster + API-server VNet integration -----------------------
  api_server_access_profile = {
    enable_private_cluster             = true
    enable_private_cluster_public_fqdn = false
    enable_vnet_integration            = true
    subnet_id                          = var.api_subnet_id
    # private_dns_zone left unset → AKS manages a system-owned private
    # DNS zone for the apiserver FQDN. The per-cluster app-ingress zone
    # authored by modules/cluster-dns is orthogonal (it resolves ingress
    # hostnames, not the apiserver).
    disable_run_command = false
  }

  # --- OIDC + workload identity (both required for Stage 2 FICs) ----------
  oidc_issuer_profile = { enabled = true }
  security_profile    = { workload_identity = { enabled = true } }

  # --- Entra-only auth ----------------------------------------------------
  enable_rbac            = true
  disable_local_accounts = true
  aad_profile = {
    managed                = true
    enable_azure_rbac      = true
    tenant_id              = var.aad.tenant_id
    admin_group_object_ids = var.aad.admin_group_object_ids
  }

  # --- Identity ----------------------------------------------------------
  managed_identities = {
    system_assigned            = false
    user_assigned_resource_ids = [azapi_resource.cluster_uami.output.id]
  }

  # --- Upgrade / autoscaler passthrough ----------------------------------
  auto_upgrade_profile = var.auto_upgrade_profile
  auto_scaler_profile  = var.auto_scaler_profile

  # --- Network profile: CNI Overlay + Cilium, CGNAT pod_cidr -------------
  network_profile = {
    network_plugin      = "azure"
    network_plugin_mode = "overlay"
    network_dataplane   = "cilium"
    network_policy      = "cilium"
    # outbound_type stays on the AVM default (loadBalancer); UDR via
    # hub egress is a follow-up once the hub firewall is modelled.
    load_balancer_sku = "standard"
    pod_cidr          = var.pod_cidr
    service_cidr      = "10.0.0.0/16"
    dns_service_ip    = "10.0.0.10"
  }

  # --- System (default) node pool ----------------------------------------
  default_agent_pool = {
    name                = "systempool"
    vm_size             = var.system_pool.vm_size
    vnet_subnet_id      = var.node_subnet_id
    enable_auto_scaling = var.system_pool.enable_auto_scaling
    min_count           = var.system_pool.min_count
    max_count           = var.system_pool.max_count
    availability_zones  = var.system_pool.zones
    os_disk_size_gb     = var.system_pool.os_disk_size_gb
    os_disk_type        = var.system_pool.os_disk_type
    max_pods            = var.system_pool.max_pods
    mode                = "System"
    node_labels         = var.system_pool.node_labels
    node_taints         = var.system_pool.node_taints
    network_profile = {
      application_security_groups = var.node_asg_ids
    }
    tags = var.tags
  }
}

# --- Optional apps node pool -----------------------------------------------
#
# Separate submodule call per AVM v0.5.x — the parent module exposes only
# `default_agent_pool`. Additional pools are created via the sibling
# `modules/agentpool` submodule; `parent_id` points at the cluster
# resource and an explicit `depends_on` ensures it runs after the
# cluster creates (the ARM API rejects early pool submissions).

module "apps_pool" {
  source  = "Azure/avm-res-containerservice-managedcluster/azurerm//modules/agentpool"
  version = "~> 0.5"

  count = var.apps_pool == null ? 0 : 1

  name      = "appspool"
  parent_id = module.aks.resource_id

  vm_size             = var.apps_pool.vm_size
  mode                = "User"
  vnet_subnet_id      = var.node_subnet_id
  enable_auto_scaling = var.apps_pool.enable_auto_scaling
  min_count           = var.apps_pool.min_count
  max_count           = var.apps_pool.max_count
  availability_zones  = var.apps_pool.zones
  os_disk_size_gb     = var.apps_pool.os_disk_size_gb
  os_disk_type        = var.apps_pool.os_disk_type
  os_sku              = "AzureLinux"
  os_type             = "Linux"
  node_labels         = var.apps_pool.node_labels
  node_taints         = var.apps_pool.node_taints

  network_profile = {
    application_security_groups = var.node_asg_ids
  }

  tags = var.tags

  depends_on = [module.aks]
}
