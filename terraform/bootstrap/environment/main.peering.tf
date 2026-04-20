# main.peering.tf
#
# Mgmt↔env peering authored from this stage (PLAN §3.4). One call to
# the AVM peering submodule per env-region with `create_reverse_peering
# = true`, so both halves of every mgmt↔env peering land in this env's
# state in a single apply.
#
# Why it works:
#   - The local half (`peer-<env>-<region>-to-mgmt`) is a child of the
#     env VNet and runs against this stage's subscription / azapi
#     provider. No extra grant required.
#   - The reverse half (`peer-mgmt-to-<env>-<region>`) is a child of
#     the mgmt VNet, which lives in `bootstrap/fleet`'s subscription.
#     `bootstrap/fleet/main.network.tf` issues a `Network Contributor`
#     role assignment on the mgmt VNet to `uami-fleet-meta` (the
#     identity that runs this stage) precisely so the reverse PUT
#     succeeds in the same apply.
#
# Hub peering for both sides is owned separately: env side by the
# sub-vending module in main.network.tf (per-VNet `hub_peering_enabled
# = true`); mgmt side by the same flag in `bootstrap/fleet/main.network.tf`.

module "mgmt_peering" {
  source  = "Azure/avm-res-network-virtualnetwork/azurerm//modules/peering"
  version = "~> 0.17"

  for_each = local.vnet_keys_by_region

  # Local half: child of the env VNet authored above.
  name                      = local.env_regions[each.value].peering_env_to_mgmt_name
  parent_id                 = local.env_vnet_id_by_region[each.key]
  remote_virtual_network_id = var.mgmt_vnet_resource_id

  allow_forwarded_traffic      = true
  allow_gateway_transit        = false
  allow_virtual_network_access = true
  use_remote_gateways          = false

  # Reverse half: child of the mgmt VNet, authored cross-subscription
  # via the role assignment granted by bootstrap/fleet.
  create_reverse_peering               = true
  reverse_name                         = local.env_regions[each.value].peering_mgmt_to_env_name
  reverse_allow_forwarded_traffic      = true
  reverse_allow_gateway_transit        = false
  reverse_allow_virtual_network_access = true
  reverse_use_remote_gateways          = false

  # The env VNet's address space can grow (CIDR widening is documented
  # in PLAN §3.4 as a PR-visible operator action). Keep the reverse
  # half in sync without manual intervention.
  sync_remote_address_space_enabled = true
  sync_remote_address_space_triggers = [
    local.env_regions[each.value].address_space,
  ]

  depends_on = [module.env_network]
}
