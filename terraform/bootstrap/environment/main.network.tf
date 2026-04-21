# main.network.tf
#
# Per-env VNets (one per region in this env), authored via the
# `Azure/avm-ptn-alz-sub-vending/azure` module (PLAN §3.4). Symmetric
# with `bootstrap/fleet/main.network.tf`: same module, but `N = count
# of regions for this env` and `mesh_peering_enabled = true` so prod
# regions / nonprod regions form a per-env intra-mesh (prod and
# nonprod never appear in the same call, by construction — this stage
# is invoked once per env).
#
# Each env-region VNet:
#   - Address space sourced from
#     networking.envs.<env>.regions.<region>.address_space.
#   - First /26 carved as `snet-pe-env` for shared per-env private
#     endpoints (Grafana PE today; future per-env services).
#   - Hub-peered (direction = both) to the adopter-owned hub.
#   - Cluster /24 slots (snet-aks-api / snet-aks-nodes) NOT created
#     here — Stage 1 azapi-authors them as children of this VNet
#     (PLAN §3.4 / Phase E).
#
# Per env-region this stage also authors:
#   - `nsg-pe-env-<env>-<region>` covering the shared PE subnet, with
#     a single Inbound 443 rule whose source is the node ASG (see
#     below). Outbound stays on the implicit Allow-Outbound default.
#   - `asg-nodes-<env>-<region>` — application security group shared
#     by every cluster in the VNet. Stage 1 attaches AKS node-pool
#     NICs to it via `agent_pools.*.network_profile.application_security_groups`.
#
# Mgmt↔env peerings live in main.peering.tf (one peering AVM call per
# region, with `create_reverse_peering = true`).

# --- Preflight on the env-region networking inputs ---------------------------
#
# Mirrors bootstrap/fleet's `terraform_data.network_preconditions`:
# fail fast with a yaml-anchored error if `_fleet.yaml` does not carry
# the required `networking.envs.<var.env>.regions.*.address_space`
# entries, before any provider call.

locals {
  # Env-scope derivations from the shared fleet-identity module, narrowed
  # to this env. Map keyed "<env>/<region>" — restrict to keys whose
  # `env == var.env`.
  env_regions = {
    for k, v in local.networking_derived.envs : k => v if v.env == var.env
  }

  # Synonyms used across this file + main.peering.tf. Sub-vending
  # `virtual_networks` and `network_security_groups` maps are keyed by
  # short identifiers (region only); resource names embed the full
  # env-region tuple via `local.env_regions[<env>/<region>]`.
  region_keys = sort(keys(local.env_regions))
}

resource "terraform_data" "network_preconditions" {
  input = {
    env          = var.env
    region_keys  = local.region_keys
    pdz_grafana  = local.networking_central.pdz_grafana
    mgmt_vnet_id = var.mgmt_vnet_resource_id
  }

  lifecycle {
    precondition {
      condition     = length(local.region_keys) > 0
      error_message = "clusters/_fleet.yaml: networking.envs.${var.env}.regions is empty or missing. At least one region with `address_space: <cidr>` must be declared. See docs/adoption.md §5.1 + PLAN §3.4."
    }
    precondition {
      condition     = alltrue([for k in local.region_keys : try(local.env_regions[k].address_space, null) != null])
      error_message = "clusters/_fleet.yaml: networking.envs.${var.env}.regions.<region>.address_space is required for every region. See docs/adoption.md §5.1 + PLAN §3.4."
    }
    precondition {
      condition     = local.networking_central.pdz_grafana != null && local.networking_central.pdz_grafana != "" && !startswith(local.networking_central.pdz_grafana, "<") && endswith(local.networking_central.pdz_grafana, "privatelink.grafana.azure.com")
      error_message = "clusters/_fleet.yaml: networking.private_dns_zones.grafana is unset, still a `<...>` placeholder, or does not end in `privatelink.grafana.azure.com`. See docs/adoption.md §5.1."
    }
  }
}

# --- Env VNets via sub-vending -----------------------------------------------
#
# A single sub-vending invocation creates `rg-net-<env>` + N region VNets
# + N PE NSGs (one per region). `mesh_peering_enabled = true` causes
# the module to author intra-env regional peerings (full mesh) when
# N > 1; at N = 1 the flag is a no-op.

locals {
  env_rg_key   = "net-${var.env}"
  env_rg_name  = "rg-net-${var.env}"
  env_location = local.location

  # Map keys passed to the sub-vending module. Use bare region names
  # (unique within an env scope) for readability of the generated state
  # addresses (`module.env_network.module.virtualnetworks["eastus"]`).
  vnet_keys_by_region = { for k, v in local.env_regions : v.region => k }

  snet_pe_env_name = "snet-pe-env"

  # NSG key per region — one NSG per VNet, attached to the PE subnet
  # via the module's subnet `key_reference` input.
  nsg_key_for_region = { for r, _ in local.vnet_keys_by_region : r => "pe-env-${r}" }
}

module "env_network" {
  source  = "Azure/avm-ptn-alz-sub-vending/azure"
  version = "~> 0.2"

  depends_on = [terraform_data.network_preconditions]

  enable_telemetry = false

  # Run against the env's already-bootstrapped subscription; do NOT
  # create or mutate the subscription.
  subscription_alias_enabled                        = false
  subscription_id                                   = local.env_sub_id
  subscription_update_existing                      = false
  subscription_management_group_association_enabled = false

  location = local.env_location

  # --- Resource group ------------------------------------------------------
  resource_group_creation_enabled = true
  resource_groups = {
    (local.env_rg_key) = {
      name     = local.env_rg_name
      location = local.env_location
      tags = {
        fleet       = local.fleet.name
        environment = var.env
        component   = "networking"
        stage       = "bootstrap-environment"
      }
    }
  }

  # --- Per-region NSGs -----------------------------------------------------
  #
  # One NSG per env-region, guarding the shared `snet-pe-env` subnet.
  # Inbound 443 from the node ASG is added separately as
  # `azapi_resource.nsg_pe_env_rule_443`, NOT inline here, because the
  # sub-vending module's `security_rules` schema does not expose
  # `sourceApplicationSecurityGroups`. Authoring the rule out-of-band
  # leaves the NSG itself owned by the module (clean delete chain) and
  # keeps the ASG-bound rule a regular azapi child resource.
  network_security_group_enabled = true
  network_security_groups = {
    for r, _ in local.vnet_keys_by_region : local.nsg_key_for_region[r] => {
      name               = local.env_regions[local.vnet_keys_by_region[r]].nsg_pe_name
      location           = r
      resource_group_key = local.env_rg_key
      security_rules     = {}
    }
  }

  # --- VNets ---------------------------------------------------------------
  virtual_network_enabled = true
  virtual_networks = {
    for r, k in local.vnet_keys_by_region : r => {
      name               = local.env_regions[k].vnet_name
      resource_group_key = local.env_rg_key
      location           = r
      address_space      = [local.env_regions[k].address_space]

      subnets = {
        pe-env = {
          name             = local.snet_pe_env_name
          address_prefixes = [local.env_regions[k].snet_pe_env_cidr]
          network_security_group = {
            key_reference = local.nsg_key_for_region[r]
          }
        }
      }

      # --- Hub peering (tohub + fromhub) ------------------------------------
      hub_peering_enabled     = true
      hub_network_resource_id = local.networking_central.hub_resource_id
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

      # Intra-env regional mesh. When N=1 this is a no-op; when N>1 the
      # sub-vending module pairs every region with every other in this
      # env. Prod and nonprod never share a call (this stage runs once
      # per env), so the mesh stays scoped to the env.
      mesh_peering_enabled = true
    }
  }
}

# --- Derived per-region resource ids ----------------------------------------
#
# Same pattern as bootstrap/fleet: the sub-vending module exposes
# `virtual_network_resource_ids[<key>]` but no subnet/NSG ids, so we
# synthesise them from the deterministic ARM path. Anchoring to the
# module output preserves the depends_on chain.

locals {
  env_vnet_id_by_region = module.env_network.virtual_network_resource_ids

  env_snet_pe_env_id_by_region = {
    for r, vnet_id in local.env_vnet_id_by_region :
    r => "${vnet_id}/subnets/${local.snet_pe_env_name}"
  }

  # NSG ids — `<rg-id>/providers/Microsoft.Network/networkSecurityGroups/<name>`.
  # The sub-vending module does not emit them; build from the env RG id.
  env_rg_id = "/subscriptions/${local.env_sub_id}/resourceGroups/${local.env_rg_name}"

  env_nsg_pe_env_id_by_region = {
    for r, k in local.vnet_keys_by_region :
    r => "${local.env_rg_id}/providers/Microsoft.Network/networkSecurityGroups/${local.env_regions[k].nsg_pe_name}"
  }
}

# --- Node ASG per region ----------------------------------------------------
#
# Shared by every AKS cluster in the env-region. Stage 1 attaches each
# node pool's NICs by passing this id into the AVM AKS module's
# `agent_pools.*.network_profile.application_security_groups`.
#
# Authored as a plain azapi resource — there is no AVM ASG module and
# the sub-vending module does not own ASGs.

resource "azapi_resource" "node_asg" {
  for_each = local.vnet_keys_by_region

  type      = "Microsoft.Network/applicationSecurityGroups@2023-11-01"
  name      = local.env_regions[each.value].node_asg_name
  parent_id = local.env_rg_id
  location  = each.key

  body = {
    properties = {}
  }
  response_export_values = ["id"]

  depends_on = [module.env_network]
}

# --- NSG rule: 443-from-node-ASG on snet-pe-env -----------------------------
#
# Allows AKS nodes in this env-region (via the shared `asg-nodes-*` ASG)
# to reach private endpoints on the env's `snet-pe-env` subnet
# (Grafana PE today; future per-env PEs). The rule is authored as a
# child of the module-owned NSG via azapi. Sub-vending's
# `security_rules` schema does not support
# `sourceApplicationSecurityGroups`, so the rule lives out-of-band.

resource "azapi_resource" "nsg_pe_env_rule_443" {
  for_each = local.vnet_keys_by_region

  type      = "Microsoft.Network/networkSecurityGroups/securityRules@2023-11-01"
  name      = "allow-nodes-to-pe-443"
  parent_id = local.env_nsg_pe_env_id_by_region[each.key]

  body = {
    properties = {
      priority                        = 100
      direction                       = "Inbound"
      access                          = "Allow"
      protocol                        = "Tcp"
      sourcePortRange                 = "*"
      destinationPortRange            = "443"
      sourceApplicationSecurityGroups = [{ id = azapi_resource.node_asg[each.key].id }]
      destinationAddressPrefix        = local.env_regions[local.vnet_keys_by_region[each.key]].snet_pe_env_cidr
      # `sourceAddressPrefix` and `destinationApplicationSecurityGroups`
      # are intentionally omitted — ARM rejects NSG rules that set both
      # an address-prefix field and its ASG counterpart. Source is ASG-
      # bound (`sourceApplicationSecurityGroups` above); destination is
      # a CIDR (`destinationAddressPrefix` above).
      description = "AKS node pools (via asg-nodes-${var.env}-${each.key}) reach env PE subnet over 443. PLAN §3.4."
    }
  }

  depends_on = [module.env_network]
}
