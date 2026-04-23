# main.network.tf
#
# Per-env cluster-workload networking (PLAN §3.4). Layout:
#
#   For env != "mgmt":
#     - `bootstrap/fleet` does NOT own the env VNet. This stage authors
#       `rg-net-<env>-<region>` + `vnet-<fleet>-<env>-<region>` via the
#       `Azure/avm-ptn-alz-sub-vending/azure` module, with N = count of
#       regions declared under `networking.envs.<env>.regions`,
#       `mesh_peering_enabled = true`, and per-VNet `hub_peering_enabled
#       = true` against
#       `networking.envs.<env>.regions.<region>.hub_network_resource_id`
#       when non-null (null = opt out, adopter-managed routing).
#     - Cluster-workload subnets (`snet-pe-env`, api pool, nodes pool),
#       node ASG, route table, and the 443-from-nodes NSG rule are
#       carved as azapi children on each VNet.
#
#   For env == "mgmt":
#     - Mgmt VNets pre-exist (authored by `bootstrap/fleet`). This stage
#       references them by id via `var.mgmt_vnet_resource_ids` (published
#       to `fleet-meta` as `MGMT_VNET_RESOURCE_IDS`, JSON-encoded).
#     - No sub-vending call. `rg-net-mgmt-<region>` and the env-PE NSG
#       also pre-exist in bootstrap/fleet's tenant scope; we author the
#       env-PE NSG here per region, under the
#       `rg-net-mgmt-<region>` RG referenced by id.
#     - Cluster-workload subnets (`snet-pe-env`, api pool, nodes pool),
#       node ASG, route table, and the 443-from-nodes NSG rule are
#       carved as azapi children on the pre-existing mgmt VNets, using
#       the `Network Contributor` grant placed on the fleet-meta UAMI
#       by `bootstrap/fleet/main.network.tf`.
#
# Either way, Stage 1 authors per-cluster `/28` api + `/25` nodes
# subnets as further azapi children, indexed by the cluster's
# `networking.subnet_slot`.
#
# Route table: `rt-aks-<env>-<region>` shell always created; the
# `0.0.0.0/0` UDR entry is created only when
# `networking.envs.<env>.regions.<region>.egress_next_hop_ip` is
# non-null. Stage 1 preconditions fail at cluster-apply time when the
# entry is missing for a region that hosts clusters (PLAN §3.4).

# --- Env-regions + key preflight --------------------------------------------

locals {
  # Per-(env,region) entries from fleet-identity, narrowed to this env.
  env_regions = {
    for k, v in local.networking_derived.envs : k => v if v.env == var.env
  }

  # Bare region names (unique within an env scope). Module keys for the
  # sub-vending call are the region name when env != "mgmt"; when
  # env == "mgmt" no sub-vending happens so this is used for
  # `for_each` only.
  region_keys         = sort(keys(local.env_regions))
  vnet_keys_by_region = { for k, v in local.env_regions : v.region => k }

  is_mgmt = var.env == "mgmt"

  # Resolve the pre-existing mgmt VNet id for this env-region (for
  # non-mgmt envs, this is the peer vnet we reverse-peer against;
  # for env=mgmt, it's the VNet we carve subnets onto). Selector:
  # same-region else first-region of the mgmt env. The mapping is
  # supplied via the tfvar `mgmt_vnet_resource_ids` keyed by mgmt
  # region — not by (env,region) — so we resolve the mgmt region
  # first. For non-mgmt envs this derivation mirrors the
  # fleet-identity `peering_mgmt_to_spoke_name` selector, which uses
  # `mgmt_regions` from the `_fleet.yaml` — keep both in sync.
  mgmt_region_keys = sort(keys(var.mgmt_vnet_resource_ids))

  # Per env-region, the selected mgmt region (always non-null — the
  # precondition below asserts `mgmt_vnet_resource_ids` is non-empty).
  mgmt_region_for_region = {
    for r, _ in local.vnet_keys_by_region :
    r => contains(local.mgmt_region_keys, r) ? r : local.mgmt_region_keys[0]
  }

  # Per env-region, the resolved mgmt VNet id. For env=mgmt this is the
  # VNet we carve subnets onto (must exist for exactly this region).
  mgmt_vnet_id_for_region = {
    for r, _ in local.vnet_keys_by_region :
    r => var.mgmt_vnet_resource_ids[local.mgmt_region_for_region[r]]
  }
}

resource "terraform_data" "network_preconditions" {
  input = {
    env                     = var.env
    region_keys             = local.region_keys
    pdz_grafana             = local.networking_central.pdz_grafana
    mgmt_vnet_resource_ids  = var.mgmt_vnet_resource_ids
    mgmt_vnet_id_for_region = local.mgmt_vnet_id_for_region
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
    # Non-mgmt: each region's hub_network_resource_id, when non-null,
    # must be a full ARM VNet resource id. Null opts out of hub peering
    # (adopter-managed routing). Mgmt's hub peering is owned by
    # bootstrap/fleet; skipped here.
    precondition {
      condition = var.env == "mgmt" || alltrue([
        for k in local.region_keys :
        local.env_regions[k].hub_network_resource_id == null ||
        can(regex("^/subscriptions/[0-9a-fA-F-]{36}/resourceGroups/[^/]+/providers/Microsoft\\.Network/virtualNetworks/[^/]+$", local.env_regions[k].hub_network_resource_id))
      ])
      error_message = "clusters/_fleet.yaml: networking.envs.${var.env}.regions.<region>.hub_network_resource_id, when set, must be a full ARM VNet resource id (or null to skip hub peering). See docs/adoption.md §5.1 + docs/networking.md."
    }
    precondition {
      condition     = local.networking_central.pdz_grafana != null && can(regex("^/subscriptions/[0-9a-fA-F-]{36}/resourceGroups/[^/]+/providers/Microsoft\\.Network/privateDnsZones/privatelink\\.grafana\\.azure\\.com$", local.networking_central.pdz_grafana))
      error_message = "clusters/_fleet.yaml: networking.private_dns_zones.grafana must be a full ARM resource id ending in `/providers/Microsoft.Network/privateDnsZones/privatelink.grafana.azure.com`. Replace it with the resource id of the central BYO Grafana PDZ. See docs/adoption.md §5.1."
    }
    # env=mgmt: each region must have a pre-authored mgmt VNet id.
    # (Non-empty check is already enforced by the variable; here we
    # assert every mgmt region named in `_fleet.yaml` has a matching
    # entry, so that the azapi carves below do not silently land on
    # the wrong VNet.)
    precondition {
      condition = var.env != "mgmt" || alltrue([
        for k in local.region_keys :
        contains(keys(var.mgmt_vnet_resource_ids), local.env_regions[k].region)
      ])
      error_message = "var.mgmt_vnet_resource_ids must contain an entry for every mgmt region declared in clusters/_fleet.yaml.networking.envs.mgmt.regions. Mismatch suggests the fleet-meta env has drifted from bootstrap/fleet's outputs."
    }
  }
}

# --- Non-mgmt env VNets via sub-vending -------------------------------------
#
# A single sub-vending invocation creates `rg-net-<env>` + N region
# VNets + N PE NSGs (one per region). `mesh_peering_enabled = true`
# causes the module to author intra-env regional peerings (full mesh)
# when N > 1; at N = 1 the flag is a no-op.
#
# Not invoked for env=mgmt: the VNets already exist (bootstrap/fleet).

locals {
  # Env net RG keys for sub-vending; one RG per env-region so the
  # name matches `rg-net-<env>-<region>` (PLAN §3.4, docs/naming.md).
  nsg_key_for_region = { for r, _ in local.vnet_keys_by_region : r => "pe-env-${r}" }

  # Alias for observability + identities modules.
  env_location = local.location
}

module "env_network" {
  source  = "Azure/avm-ptn-alz-sub-vending/azure"
  version = "~> 0.2"

  count = local.is_mgmt ? 0 : 1

  depends_on = [terraform_data.network_preconditions]

  enable_telemetry = false

  subscription_alias_enabled                        = false
  subscription_id                                   = local.env_sub_id
  subscription_update_existing                      = false
  subscription_management_group_association_enabled = false

  location = local.location

  # --- Resource group: one per env-region ---------------------------------
  #
  # Historically this stage created a single `rg-net-<env>` that held
  # every region's VNet. PLAN §3.4 / docs/naming.md names the net RG
  # per env-region (`rg-net-<env>-<region>`) so it matches mgmt's
  # bootstrap/fleet-owned layout and so route-table / ASG resources
  # parent cleanly to the right location-scoped RG.
  resource_group_creation_enabled = true
  resource_groups = {
    for r, k in local.vnet_keys_by_region :
    "net-${r}" => {
      name     = local.env_regions[k].rg_name # rg-net-<env>-<region>
      location = r
      tags = {
        fleet       = local.fleet.name
        environment = var.env
        component   = "networking"
        stage       = "bootstrap-environment"
        region      = r
      }
    }
  }

  # --- Per-region NSGs for snet-pe-env ------------------------------------
  #
  # One NSG per env-region, guarding the cluster-workload PE subnet.
  # Inbound 443 from the node ASG is added out-of-band as
  # `azapi_resource.nsg_pe_env_rule_443` because the sub-vending module
  # does not expose `sourceApplicationSecurityGroups` in its
  # `security_rules` schema.
  network_security_group_enabled = true
  network_security_groups = {
    for r, _ in local.vnet_keys_by_region : local.nsg_key_for_region[r] => {
      name               = local.env_regions[local.vnet_keys_by_region[r]].nsg_pe_env_name
      location           = r
      resource_group_key = "net-${r}"
      security_rules     = {}
    }
  }

  # --- VNets --------------------------------------------------------------
  virtual_network_enabled = true
  virtual_networks = {
    for r, k in local.vnet_keys_by_region : r => {
      name               = local.env_regions[k].vnet_name
      resource_group_key = "net-${r}"
      location           = r
      address_space      = local.env_regions[k].address_space

      # Cluster-workload subnets are authored as azapi children below
      # (uniform with the env=mgmt branch). Sub-vending's subnet carve
      # is therefore empty here; we rely on the module solely for the
      # VNet shell + RG + NSG + hub peering.
      subnets = {}

      # --- Hub peering (tohub + fromhub) ----------------------------------
      #
      # Nullable per env-region: null opts out (adopter-managed
      # routing). Sub-vending requires a non-null string on the
      # variable schema, so pass an empty sentinel when disabled.
      hub_peering_enabled     = local.env_regions[k].hub_network_resource_id != null
      hub_network_resource_id = local.env_regions[k].hub_network_resource_id != null ? local.env_regions[k].hub_network_resource_id : ""
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

      # Intra-env regional mesh. When N=1 this is a no-op; when N>1
      # the module pairs every region with every other in this env.
      mesh_peering_enabled = true
    }
  }
}

# --- Per-region NSG for snet-pe-env (env=mgmt branch) -----------------------
#
# For env=mgmt the VNet already exists and sub-vending is not invoked,
# so the env-PE NSG must be authored directly here. Placed in
# `rg-net-mgmt-<region>` (bootstrap/fleet-owned); fleet-meta has
# Contributor on the mgmt subscription via bootstrap/environment's
# `ra_meta_sub_contrib`, so the create+delete chain works.

resource "azapi_resource" "nsg_pe_env_mgmt" {
  for_each = local.is_mgmt ? local.vnet_keys_by_region : {}

  type      = "Microsoft.Network/networkSecurityGroups@2023-11-01"
  name      = local.env_regions[each.value].nsg_pe_env_name
  parent_id = "/subscriptions/${local.env_sub_id}/resourceGroups/rg-net-mgmt-${each.key}"
  location  = each.key

  body = {
    properties = {
      securityRules = []
    }
  }
  response_export_values = ["id"]
}

# --- Derived per-region resource ids ----------------------------------------
#
# Sub-vending module exposes `virtual_network_resource_ids[<key>]` (for
# non-mgmt) but no subnet / RG ids. For env=mgmt we thread
# `var.mgmt_vnet_resource_ids` through. Both branches are fused into a
# single uniform map.

locals {
  # Env VNet id per region. For env=mgmt comes from the tfvar; for
  # non-mgmt from the sub-vending module output.
  env_vnet_id_by_region = (
    local.is_mgmt
    ? local.mgmt_vnet_id_for_region
    : module.env_network[0].virtual_network_resource_ids
  )

  # Env net RG id per region, used as parent for env-scope network
  # resources (route table, node ASG, etc.).
  env_net_rg_id_by_region = {
    for r, k in local.vnet_keys_by_region :
    r => "/subscriptions/${local.env_sub_id}/resourceGroups/${local.env_regions[k].rg_name}"
  }

  # Env-PE NSG id per region.
  env_nsg_pe_env_id_by_region = local.is_mgmt ? {
    for r, n in azapi_resource.nsg_pe_env_mgmt : r => n.id
    } : {
    for r, k in local.vnet_keys_by_region :
    r => "${local.env_net_rg_id_by_region[r]}/providers/Microsoft.Network/networkSecurityGroups/${local.env_regions[k].nsg_pe_env_name}"
  }
}

# --- Uniform cluster-workload subnets (all envs, via azapi) -----------------
#
# `snet-pe-env` — first /26 of the cluster-reserved zone. Houses env
# Grafana PE, per-cluster PEs (including the mgmt cluster KV PE on
# mgmt VNets). Attached to `nsg-pe-env-<env>-<region>`.
#
# Authored as an azapi child of the env VNet, even for non-mgmt where
# the VNet itself is a sub-vending output — this keeps subnet
# authoring uniform across both branches and makes the add-api-pool /
# add-nodes-pool dance below work identically.

resource "azapi_resource" "snet_pe_env" {
  for_each = local.vnet_keys_by_region

  type      = "Microsoft.Network/virtualNetworks/subnets@2023-11-01"
  name      = "snet-pe-env"
  parent_id = local.env_vnet_id_by_region[each.key]

  body = {
    properties = {
      addressPrefixes      = [local.env_regions[each.value].snet_pe_env_cidr]
      networkSecurityGroup = { id = local.env_nsg_pe_env_id_by_region[each.key] }
      routeTable           = { id = azapi_resource.route_table[each.key].id }
    }
  }
  response_export_values = ["id"]

  depends_on = [module.env_network, azapi_resource.nsg_pe_env_mgmt]
}

# --- API + nodes pool placeholder subnets -----------------------------------
#
# PLAN §3.4 / §4.1 reserve the second /24 of the env-region VNet for
# per-cluster `/28` api subnets, and /24 index 2+ for per-cluster
# `/25` nodes subnets. Stage 1 carves each cluster's own slot as a
# further azapi child indexed by `subnet_slot`. THIS stage owns only
# the route table + the per-env-region ASG; the /24 pools themselves
# are pure address-space reservations and have no corresponding
# subnet resource (ARM does not model "reserved address ranges"
# below a VNet — the reservation is implicit via the fleet-identity
# slot arithmetic).
#
# Therefore: no resources here for the api/nodes pools. Stage 1 emits
# them per cluster with `routeTableId` pointing at
# `azapi_resource.route_table[region].id`.

# --- Route table per env-region ---------------------------------------------
#
# Shell always created. The `0.0.0.0/0` → `egress_next_hop_ip` route
# entry is conditional: populated only when the adopter has set
# `networking.envs.<env>.regions.<region>.egress_next_hop_ip` in
# `_fleet.yaml`. Stage 1 preconditions fail at cluster apply for a
# region with clusters but no entry.

resource "azapi_resource" "route_table" {
  for_each = local.vnet_keys_by_region

  type      = "Microsoft.Network/routeTables@2023-11-01"
  name      = local.env_regions[each.value].route_table_name
  parent_id = local.env_net_rg_id_by_region[each.key]
  location  = each.key

  body = {
    properties = {
      disableBgpRoutePropagation = false
    }
  }
  response_export_values = ["id"]

  depends_on = [module.env_network]
}

resource "azapi_resource" "route_table_default_route" {
  for_each = {
    for r, k in local.vnet_keys_by_region :
    r => k if local.env_regions[k].egress_next_hop_ip != null
  }

  type      = "Microsoft.Network/routeTables/routes@2023-11-01"
  name      = "default-0000-egress"
  parent_id = azapi_resource.route_table[each.key].id

  body = {
    properties = {
      addressPrefix    = "0.0.0.0/0"
      nextHopType      = "VirtualAppliance"
      nextHopIpAddress = local.env_regions[each.value].egress_next_hop_ip
    }
  }
}

# --- Node ASG per region ----------------------------------------------------
#
# Shared by every AKS cluster in the env-region. Stage 1 attaches each
# node pool's NICs by passing this id into the AVM AKS module's
# `agent_pools.*.network_profile.application_security_groups`.

resource "azapi_resource" "node_asg" {
  for_each = local.vnet_keys_by_region

  type      = "Microsoft.Network/applicationSecurityGroups@2023-11-01"
  name      = local.env_regions[each.value].node_asg_name
  parent_id = local.env_net_rg_id_by_region[each.key]
  location  = each.key

  body = {
    properties = {}
  }
  response_export_values = ["id"]

  depends_on = [module.env_network]
}

# --- NSG rule: 443-from-node-ASG on snet-pe-env -----------------------------
#
# Allows AKS nodes in this env-region (via the shared `asg-nodes-*`
# ASG) to reach private endpoints on `snet-pe-env` (env Grafana today;
# future per-env PEs; for mgmt additionally the mgmt cluster KV PE).
# Authored as an azapi child of the NSG (module-owned on non-mgmt,
# this-stage-owned on mgmt) because the sub-vending `security_rules`
# schema does not expose `sourceApplicationSecurityGroups`.

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
      destinationAddressPrefix        = local.env_regions[each.value].snet_pe_env_cidr
      description                     = "AKS node pools (via asg-nodes-${var.env}-${each.key}) reach env PE subnet over 443. PLAN §3.4."
    }
  }

  depends_on = [module.env_network, azapi_resource.nsg_pe_env_mgmt]
}

# --- Derived snet-pe-env id (stable output) ---------------------------------

locals {
  env_snet_pe_env_id_by_region = {
    for r, s in azapi_resource.snet_pe_env : r => s.id
  }
}
