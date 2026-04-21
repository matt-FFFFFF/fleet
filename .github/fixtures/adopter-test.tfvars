# Fixture for template-selftest.yaml. Overlaid onto init/inputs.auto.tfvars
# by init-fleet.sh --values-file so the repo can be validated end-to-end
# without prompts. Values are synthetic; real adopters use their own.

fleet_name         = "acme"
fleet_display_name = "Acme Platform"
tenant_id          = "11111111-1111-1111-1111-111111111111"
github_org         = "acme-co"
github_repo        = "platform-fleet"
team_template_repo = "team-repo-template"
primary_region     = "eastus"
sub_shared         = "22222222-2222-2222-2222-222222222222"
dns_fleet_root     = "int.acme.example"

# Networking (PLAN §3.1 / §3.4) — BYO central PDZs. Per-env identity and
# networking (subscription id, VNet CIDR, hub reference) live in
# `environments` below. `hub_network_resource_id` is nullable on every
# env (including mgmt); null opts out of hub peering for that env-region.
networking_pdz_blob      = "/subscriptions/66666666-6666-6666-6666-666666666666/resourceGroups/rg-hub-dns/providers/Microsoft.Network/privateDnsZones/privatelink.blob.core.windows.net"
networking_pdz_vaultcore = "/subscriptions/66666666-6666-6666-6666-666666666666/resourceGroups/rg-hub-dns/providers/Microsoft.Network/privateDnsZones/privatelink.vaultcore.azure.net"
networking_pdz_azurecr   = "/subscriptions/66666666-6666-6666-6666-666666666666/resourceGroups/rg-hub-dns/providers/Microsoft.Network/privateDnsZones/privatelink.azurecr.io"
networking_pdz_grafana   = "/subscriptions/66666666-6666-6666-6666-666666666666/resourceGroups/rg-hub-dns/providers/Microsoft.Network/privateDnsZones/privatelink.grafana.azure.com"

environments = {
  mgmt = {
    subscription_id         = "33333333-3333-3333-3333-333333333333"
    address_space           = "10.50.0.0/20"
    hub_network_resource_id = "/subscriptions/66666666-6666-6666-6666-666666666666/resourceGroups/rg-hub/providers/Microsoft.Network/virtualNetworks/vnet-hub-mgmt-eastus"
  }
  nonprod = {
    subscription_id         = "44444444-4444-4444-4444-444444444444"
    address_space           = "10.70.0.0/20"
    hub_network_resource_id = "/subscriptions/66666666-6666-6666-6666-666666666666/resourceGroups/rg-hub/providers/Microsoft.Network/virtualNetworks/vnet-hub-nonprod-eastus"
  }
  prod = {
    subscription_id         = "55555555-5555-5555-5555-555555555555"
    address_space           = "10.80.0.0/20"
    hub_network_resource_id = "/subscriptions/66666666-6666-6666-6666-666666666666/resourceGroups/rg-hub/providers/Microsoft.Network/virtualNetworks/vnet-hub-prod-eastus"
  }
}
