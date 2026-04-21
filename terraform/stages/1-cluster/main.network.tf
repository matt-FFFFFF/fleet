# stages/1-cluster/main.network.tf
#
# Per-cluster subnets authored as azapi children of the env VNet. Two
# subnets per cluster, indexed by `networking.subnet_slot` (PLAN §3.4):
#
#   snet-aks-api-<name>   — /28 in the env VNet's API pool, delegated to
#                           Microsoft.ContainerService/managedClusters so
#                           the AKS control plane can ingest it via
#                           api-server VNet integration (private cluster).
#   snet-aks-nodes-<name> — /25 in the env VNet's nodes pool, used as
#                           vnet_subnet_id for every agent pool. Pod IPs
#                           come from the fleet-wide shared /16 in CGNAT
#                           (100.64.0.0/16, hard-coded in
#                           modules/aks-cluster) via CNI Overlay + Cilium,
#                           so this subnet only holds node NICs + internal
#                           load balancers.
#
# CIDRs arrive from the loader as `derived.networking.snet_aks_{api,nodes}_cidr`
# (derivation in config-loader/load.sh + docs/naming.md). Subnet names
# arrive pre-formatted (`snet-aks-{api,nodes}-<cluster.name>`) as
# `derived.networking.snet_aks_{api,nodes}_name`.
#
# We do NOT touch the parent VNet, its NSGs, or the env ASG here — those
# are owned by `bootstrap/environment`. The cluster lifecycle is thus
# independent of env-VNet re-applies (PLAN §3.4).

resource "azapi_resource" "snet_aks_api" {
  type      = "Microsoft.Network/virtualNetworks/subnets@2023-11-01"
  name      = local.net.snet_aks_api_name
  parent_id = var.env_region_vnet_resource_id

  body = {
    properties = {
      addressPrefix = local.net.snet_aks_api_cidr
      # AKS api-server VNet integration requires the subnet be
      # delegated to `Microsoft.ContainerService/managedClusters`
      # and otherwise empty. /28 is the minimum (and, per AKS docs,
      # the *only* supported) size.
      delegations = [{
        name = "aks-apiserver"
        properties = {
          serviceName = "Microsoft.ContainerService/managedClusters"
        }
      }]
      # No NSG attached at the api subnet: the delegated API-server
      # infra manages its own traffic. Attaching an NSG here can
      # break control-plane health probes on some AKS versions.
      privateEndpointNetworkPolicies    = "Disabled"
      privateLinkServiceNetworkPolicies = "Enabled"
    }
  }

  response_export_values = ["id"]

  depends_on = [terraform_data.network_preconditions]

  lifecycle {
    precondition {
      condition     = can(cidrhost(local.net.snet_aks_api_cidr, 0)) && split("/", local.net.snet_aks_api_cidr)[1] == "28"
      error_message = "derived.networking.snet_aks_api_cidr must be /28 (AKS api-server VNet-integration requirement). Got: ${local.net.snet_aks_api_cidr}"
    }
  }
}

resource "azapi_resource" "snet_aks_nodes" {
  type      = "Microsoft.Network/virtualNetworks/subnets@2023-11-01"
  name      = local.net.snet_aks_nodes_name
  parent_id = var.env_region_vnet_resource_id

  body = {
    properties = {
      addressPrefix                     = local.net.snet_aks_nodes_cidr
      privateEndpointNetworkPolicies    = "Disabled"
      privateLinkServiceNetworkPolicies = "Enabled"
      # No delegations on the nodes subnet — AKS attaches node NICs
      # directly. ASG membership is asserted on each agent pool via
      # networkProfile.applicationSecurityGroups (the env-scope
      # asg-nodes-<env>-<region>), not on the subnet itself, so
      # future clusters in the same VNet can share the ASG without
      # subnet-level coupling.
    }
  }

  response_export_values = ["id"]

  depends_on = [terraform_data.network_preconditions]

  lifecycle {
    precondition {
      condition     = can(cidrhost(local.net.snet_aks_nodes_cidr, 0)) && tonumber(split("/", local.net.snet_aks_nodes_cidr)[1]) <= 25
      error_message = "derived.networking.snet_aks_nodes_cidr must be /25 or larger (smaller allocations break agent-pool scale ceiling with CNI Overlay). Got: ${local.net.snet_aks_nodes_cidr}"
    }
  }
}

# Derived ids reused by the AKS module + DNS zone link below. Keeps the
# aks-cluster module call readable (subnet_ids as a map, not two scalar
# args) and lets follow-up commits add a third subnet (e.g. pod subnet
# for a non-Overlay CNI) without reshuffling module inputs.
locals {
  cluster_subnet_ids = {
    api   = azapi_resource.snet_aks_api.output.id
    nodes = azapi_resource.snet_aks_nodes.output.id
  }
}
