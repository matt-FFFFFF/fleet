# main.network.tf
#
# Repo-owned mgmt env-region VNet shells (PLAN §3.4). Authored via the
# `Azure/avm-ptn-alz-sub-vending/azure` module, one invocation per
# `networking.envs.mgmt.regions.<region>` entry in _fleet.yaml. Each
# invocation creates:
#
#   - `vnet-<fleet.name>-mgmt-<region>` in `rg-net-mgmt-<region>`,
#     hub-peered to the hub selected for (mgmt_environment_for_vnet_peering,
#     region) from `networking.hubs`.
#   - Fleet-plane subnets (HIGH end of the /20, second /21 by PLAN §3.4):
#       * `snet-pe-fleet` — /26 for tfstate SA, fleet KV, fleet ACR PEs.
#         NSG `nsg-pe-fleet-<region>`.
#       * `snet-runners` — /23 delegated to Microsoft.App/environments
#         for the ACA runner pool. NSG `nsg-runners-<region>`.
#
# The sub-vending module does NOT pre-create cluster-workload subnets
# (api pool, nodes pool, env-PE, node ASG, route table) — those are
# carved by `bootstrap/environment` as azapi children of the VNets this
# stage creates, authenticated via the `Network Contributor` grant
# placed on the `fleet-meta` UAMI at each mgmt env-region VNet below.
#
# Downstream PEs (tfstate SA, fleet KV, fleet ACR) register into the
# snet-pe-fleet of a single chosen mgmt region per resource — see the
# `state_mgmt_region`, `fleet_kv_mgmt_region`, and `runner_mgmt_region`
# selectors in main.state.tf / main.kv.tf / main.runner.tf.

# --- Preflight -------------------------------------------------------------
#
# Reject partial / malformed networking inputs with a single yaml-anchored
# error before the sub-vending module runs. Checks:
#   - At least one `networking.envs.mgmt.regions.<region>` entry;
#   - Each mgmt region has a non-null /20-or-larger address_space;
#   - Each mgmt region names a `mgmt_environment_for_vnet_peering` that
#     resolves to a hub in `networking.hubs.<env>.regions.<region>` for
#     the same region;
#   - Central PDZs (blob + vaultcore + azurecr) are populated.

locals {
  # Per-(env,region) entries from fleet-identity, filtered to env=mgmt.
  mgmt_regions = {
    for key, e in local.networking_derived.envs : key => e
    if e.env == "mgmt"
  }

  # For each mgmt region, resolve the hub VNet id it peers into. Shape:
  # "<peer_env>/<region>" keyed into `networking_central.hubs`.
  mgmt_hub_ids = {
    for key, e in local.mgmt_regions :
    key => try(
      local.networking_central.hubs["${e.mgmt_environment_for_vnet_peering}/${e.region}"],
      null,
    )
  }
}

resource "terraform_data" "network_preconditions" {
  input = {
    mgmt_region_count = length(local.mgmt_regions)
    mgmt_regions      = local.mgmt_regions
    mgmt_hub_ids      = local.mgmt_hub_ids
    pdz_blob          = local.networking_central.pdz_blob
    pdz_vaultcore     = local.networking_central.pdz_vaultcore
    pdz_azurecr       = local.networking_central.pdz_azurecr
  }

  lifecycle {
    precondition {
      condition     = length(local.mgmt_regions) > 0
      error_message = "clusters/_fleet.yaml: networking.envs.mgmt.regions must declare at least one region. See docs/adoption.md §5.1 + PLAN §3.4."
    }
    precondition {
      condition = alltrue([
        for key, e in local.mgmt_regions :
        e.cidr != null && can(cidrnetmask(e.cidr)) && tonumber(split("/", e.cidr)[1]) <= 20
      ])
      error_message = "clusters/_fleet.yaml: every networking.envs.mgmt.regions.<region>.address_space must be a valid CIDR with prefix ≤ /20 (fleet-plane zone requires upper /21). See PLAN §3.4."
    }
    precondition {
      condition = alltrue([
        for key, e in local.mgmt_regions :
        e.mgmt_environment_for_vnet_peering != null && trimspace(e.mgmt_environment_for_vnet_peering) != ""
      ])
      error_message = "clusters/_fleet.yaml: every networking.envs.mgmt.regions.<region> must declare `mgmt_environment_for_vnet_peering` naming the non-mgmt env whose hub this mgmt VNet peers into. See PLAN §3.1 + §3.4."
    }
    precondition {
      condition = alltrue([
        for key, hub in local.mgmt_hub_ids :
        hub != null && can(regex("^/subscriptions/[0-9a-fA-F-]{36}/resourceGroups/[^/]+/providers/Microsoft\\.Network/virtualNetworks/[^/]+$", hub))
      ])
      error_message = "clusters/_fleet.yaml: networking.hubs.<mgmt_environment_for_vnet_peering>.regions.<region>.resource_id must exist and be a full ARM VNet resource id for every mgmt region. See docs/adoption.md §5.1 + docs/networking.md."
    }
    precondition {
      condition     = local.networking_central.pdz_blob != null && can(regex("^/subscriptions/[0-9a-fA-F-]{36}/resourceGroups/[^/]+/providers/Microsoft\\.Network/privateDnsZones/privatelink\\.blob\\.core\\.windows\\.net$", local.networking_central.pdz_blob))
      error_message = "clusters/_fleet.yaml: networking.private_dns_zones.blob must be a full ARM resource id ending in `/providers/Microsoft.Network/privateDnsZones/privatelink.blob.core.windows.net`. See docs/adoption.md §5.1."
    }
    precondition {
      condition     = local.networking_central.pdz_vaultcore != null && can(regex("^/subscriptions/[0-9a-fA-F-]{36}/resourceGroups/[^/]+/providers/Microsoft\\.Network/privateDnsZones/privatelink\\.vaultcore\\.azure\\.net$", local.networking_central.pdz_vaultcore))
      error_message = "clusters/_fleet.yaml: networking.private_dns_zones.vaultcore must be a full ARM resource id ending in `/providers/Microsoft.Network/privateDnsZones/privatelink.vaultcore.azure.net`. See docs/adoption.md §5.1."
    }
    precondition {
      condition     = local.networking_central.pdz_azurecr != null && can(regex("^/subscriptions/[0-9a-fA-F-]{36}/resourceGroups/[^/]+/providers/Microsoft\\.Network/privateDnsZones/privatelink\\.azurecr\\.io$", local.networking_central.pdz_azurecr))
      error_message = "clusters/_fleet.yaml: networking.private_dns_zones.azurecr must be a full ARM resource id ending in `/providers/Microsoft.Network/privateDnsZones/privatelink.azurecr.io`. See docs/adoption.md §5.1."
    }
  }
}

# --- Mgmt env-region VNets via sub-vending ---------------------------------
#
# One module invocation per mgmt region. Each invocation creates a
# single VNet (N=1, no intra-call mesh). When there are multiple mgmt
# regions we rely on operator convention to peer them out-of-band — the
# fleet plane is intentionally single-region in the worked example, so
# N>1 is unusual.

locals {
  # Internal map keys for sub-vending. One VNet and one RG key per
  # mgmt region; NSG keys are shared across regions since each module
  # invocation is scoped to a single region.
  mgmt_rg_key      = "net-mgmt"
  mgmt_vnet_key    = "mgmt"
  nsg_pe_fleet_key = "pe-fleet"
  nsg_runners_key  = "runners"
}

module "mgmt_network" {
  source   = "Azure/avm-ptn-alz-sub-vending/azure"
  version  = "~> 0.2"
  for_each = local.mgmt_regions

  depends_on = [terraform_data.network_preconditions]

  enable_telemetry = false

  # Run against the already-bootstrapped shared subscription; do NOT
  # create or mutate the subscription.
  subscription_alias_enabled                        = false
  subscription_id                                   = local.derived.acr_subscription_id
  subscription_update_existing                      = false
  subscription_management_group_association_enabled = false

  location = each.value.location

  # --- Resource group ------------------------------------------------------
  resource_group_creation_enabled = true
  resource_groups = {
    (local.mgmt_rg_key) = {
      name     = each.value.rg_name # rg-net-mgmt-<region>
      location = each.value.location
      tags = {
        fleet     = local.fleet.name
        component = "networking"
        stage     = "bootstrap-fleet"
        env       = "mgmt"
        region    = each.value.region
      }
    }
  }

  # --- NSGs ----------------------------------------------------------------
  network_security_group_enabled = true
  network_security_groups = {
    (local.nsg_pe_fleet_key) = {
      name               = each.value.nsg_pe_fleet_name # nsg-pe-fleet-<region>
      location           = each.value.location
      resource_group_key = local.mgmt_rg_key
      # Default-deny only — PE subnets need no explicit ingress; the PLS
      # handles the traffic.
      security_rules = {}
    }
    (local.nsg_runners_key) = {
      name               = each.value.nsg_runners_name # nsg-runners-<region>
      location           = each.value.location
      resource_group_key = local.mgmt_rg_key
      # Outbound-only: ACA jobs reach GitHub + Azure control plane via
      # hub firewall (UDR on the subnet). No ingress required.
      security_rules = {}
    }
  }

  # --- VNet + fleet-plane subnets ------------------------------------------
  virtual_network_enabled = true
  virtual_networks = {
    (local.mgmt_vnet_key) = {
      name               = each.value.vnet_name # vnet-<fleet>-mgmt-<region>
      resource_group_key = local.mgmt_rg_key
      location           = each.value.location
      address_space      = each.value.address_space

      # Fleet-plane subnets only. Cluster-workload subnets
      # (snet-pe-env, api pool, nodes pool) are carved by
      # bootstrap/environment as azapi children under the Network
      # Contributor grant below.
      subnets = {
        pe-fleet = {
          name             = "snet-pe-fleet"
          address_prefixes = [each.value.snet_pe_fleet_cidr]
          network_security_group = {
            key_reference = local.nsg_pe_fleet_key
          }
        }
        runners = {
          name             = "snet-runners"
          address_prefixes = [each.value.snet_runners_cidr]
          network_security_group = {
            key_reference = local.nsg_runners_key
          }
          # ACA requires delegation to Microsoft.App/environments on the
          # subnet; the vendored runner module expects a pre-delegated
          # subnet.
          delegations = [
            {
              name = "Microsoft.App.environments"
              service_delegation = {
                name    = "Microsoft.App/environments"
                actions = ["Microsoft.Network/virtualNetworks/subnets/action"]
              }
            }
          ]
        }
      }

      # --- Hub peering (tohub + fromhub) -----------------------------------
      hub_peering_enabled     = true
      hub_network_resource_id = local.mgmt_hub_ids[each.key]
      hub_peering_direction   = "both"
      hub_peering_options_tohub = {
        allow_forwarded_traffic      = true
        allow_gateway_transit        = false
        allow_virtual_network_access = true
        use_remote_gateways          = false
      }
      hub_peering_options_fromhub = {
        allow_forwarded_traffic      = true
        allow_gateway_transit        = true
        allow_virtual_network_access = true
        use_remote_gateways          = false
      }

      # Intra-mesh peering is N/A at N=1 per invocation; cross-region
      # mgmt mesh (if ever needed) is adopter-owned out-of-band.
      mesh_peering_enabled = false
    }
  }
}

# --- Per-region VNet + subnet resource ids ---------------------------------
#
# The sub-vending module does not expose subnet resource ids directly
# (only `virtual_network_resource_ids[key]`). Subnet ids follow the
# deterministic ARM path `<vnet-id>/subnets/<name>`, so we build them
# from the VNet output. Maps keyed by region (NOT by env/region pair)
# since `env` is always "mgmt" on this stack.

locals {
  mgmt_vnet_ids = {
    for key, e in local.mgmt_regions :
    e.region => module.mgmt_network[key].virtual_network_resource_ids[local.mgmt_vnet_key]
  }
  mgmt_snet_pe_fleet_ids = {
    for region, vnet_id in local.mgmt_vnet_ids :
    region => "${vnet_id}/subnets/snet-pe-fleet"
  }
  mgmt_snet_runners_ids = {
    for region, vnet_id in local.mgmt_vnet_ids :
    region => "${vnet_id}/subnets/snet-runners"
  }
}

# --- RBAC: fleet-meta UAMI → Network Contributor per mgmt VNet -------------
#
# `bootstrap/environment` carves cluster-workload subnets onto these
# pre-existing mgmt VNets (PLAN §4 Stage -1 `bootstrap/environment` for
# env=mgmt branch) and authors the mgmt→spoke half of every non-mgmt
# env-region peering when `create_reverse_peering = true`. Both
# operations PUT on the mgmt VNet in this stage's subscription, so the
# `fleet-meta` UAMI needs Network Contributor at each mgmt VNet's
# resource id.
#
# Built-in role GUID: Network Contributor 4d97b98b-1d4f-4787-a291-c67834d212e7

locals {
  role_network_contributor_guid = "4d97b98b-1d4f-4787-a291-c67834d212e7"
}

resource "azapi_resource" "ra_meta_mgmt_vnet_netctrb" {
  for_each = local.mgmt_vnet_ids

  type      = "Microsoft.Authorization/roleAssignments@2022-04-01"
  name      = uuidv5("url", "fleet-meta-mgmt-vnet-netctrb-${each.value}")
  parent_id = each.value

  body = {
    properties = {
      roleDefinitionId = "/subscriptions/${local.derived.acr_subscription_id}/providers/Microsoft.Authorization/roleDefinitions/${local.role_network_contributor_guid}"
      principalId      = module.fleet_repo.environments["meta"].identity.principal_id
      principalType    = "ServicePrincipal"
    }
  }
}
