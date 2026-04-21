# modules/cluster-dns/main.tf
#
# Per-cluster private DNS zone + VNet links. PLAN §3.4:
#
#   - Zone at `<cluster>.<region>.<env>.<fleet_root>` (derived by
#     config-loader; see naming.md).
#   - Linked to `[env VNet, mgmt VNet]` — mgmt link enables Kargo +
#     fleet-wide tooling to resolve cluster hostnames; env link covers
#     sibling clusters that land in the same VNet.
#   - Role assignment (`Private DNS Zone Contributor` → external-dns
#     UAMI) is authored by Stage 1 once that UAMI exists. Scope is the
#     zone's resource id, not the resource group — a cluster's
#     external-dns cannot touch any other zone.

resource "azapi_resource" "zone" {
  type      = "Microsoft.Network/privateDnsZones@2020-06-01"
  name      = var.zone_fqdn
  parent_id = var.parent_id
  # Private DNS zones are global resources — location is always `global`
  # and the API rejects any other value.
  location = "global"

  body = {
    properties = {}
  }

  response_export_values = ["id"]

  tags = var.tags
}

# One virtualNetworkLinks child per entry in var.linked_vnet_ids. The
# map key becomes part of the link resource name so adding a link is an
# additive diff (no rename of existing state addresses).
resource "azapi_resource" "vnet_link" {
  for_each = var.linked_vnet_ids

  type      = "Microsoft.Network/privateDnsZones/virtualNetworkLinks@2020-06-01"
  name      = "link-${each.key}"
  parent_id = azapi_resource.zone.output.id
  location  = "global"

  body = {
    properties = {
      virtualNetwork      = { id = each.value }
      registrationEnabled = false # external-dns owns record writes
    }
  }

  tags = var.tags
}
