# main.peering.tf
#
# Mgmt↔env peering authored from this stage (PLAN §3.4). One call to
# the AVM peering submodule per env-region with `create_reverse_peering
# = networking.envs.<env>.regions.<region>.create_reverse_peering`
# (default true), so both halves of every mgmt↔env peering land in
# this env's state in a single apply (when enabled).
#
# Skipped entirely for env=mgmt: mgmt VNets don't peer to themselves.
# Mgmt's only cross-VNet peerings are the hub peering emitted by
# `bootstrap/fleet`'s sub-vending call and the reverse halves authored
# by other envs' `bootstrap/environment` runs.
#
# Why the local side works: it's a child of the env VNet authored
# above (or, for env=mgmt we don't author anything, so this file is a
# no-op there).
#
# Why the reverse side works (when enabled): child of the mgmt VNet,
# which lives in `bootstrap/fleet`'s subscription. `bootstrap/fleet`
# issues a `Network Contributor` role assignment on each mgmt VNet to
# `uami-fleet-meta` precisely so the reverse PUT succeeds
# cross-subscription.
#
# Hub peering for both sides is owned separately: env side by the
# sub-vending module in main.network.tf (per-VNet `hub_peering_enabled
# = true`); mgmt side by the same flag in
# `bootstrap/fleet/main.network.tf`.

module "mgmt_peering" {
  source  = "Azure/avm-res-network-virtualnetwork/azurerm//modules/peering"
  version = "~> 0.17"

  # One peering module call per env-region, skipping env=mgmt entirely.
  # The peer mgmt region is resolved in main.network.tf
  # (`local.mgmt_region_for_region`) via same-region-else-first — must
  # match the fleet-identity peering-name derivation, which uses the
  # same rule.
  for_each = local.is_mgmt ? {} : local.vnet_keys_by_region

  # Local half: child of the env VNet.
  name                      = local.env_regions[each.value].peering_spoke_to_mgmt_name
  parent_id                 = local.env_vnet_id_by_region[each.key]
  remote_virtual_network_id = local.mgmt_vnet_id_for_region[each.key]

  allow_forwarded_traffic      = true
  allow_gateway_transit        = false
  allow_virtual_network_access = true
  use_remote_gateways          = false

  # Reverse half: child of the mgmt VNet, authored cross-subscription
  # via the role assignment granted by bootstrap/fleet. Gated per
  # env-region by `create_reverse_peering` (default true).
  create_reverse_peering               = local.env_regions[each.value].create_reverse_peering
  reverse_name                         = local.env_regions[each.value].peering_mgmt_to_spoke_name
  reverse_allow_forwarded_traffic      = true
  reverse_allow_gateway_transit        = false
  reverse_allow_virtual_network_access = true
  reverse_use_remote_gateways          = false

  # The env VNet's address space can grow (CIDR widening is documented
  # in PLAN §3.4 as a PR-visible operator action). Keep the reverse
  # half in sync without manual intervention when it exists.
  sync_remote_address_space_enabled = local.env_regions[each.value].create_reverse_peering
  sync_remote_address_space_triggers = [
    local.env_regions[each.value].address_space[0],
  ]

  depends_on = [module.env_network]
}
