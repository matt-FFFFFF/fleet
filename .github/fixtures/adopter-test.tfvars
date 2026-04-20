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
sub_mgmt           = "33333333-3333-3333-3333-333333333333"
sub_nonprod        = "44444444-4444-4444-4444-444444444444"
sub_prod           = "55555555-5555-5555-5555-555555555555"
dns_fleet_root     = "int.acme.example"

# Networking (PLAN §3.4) — BYO hub + central PDZs + four repo-owned VNets.
networking_hub_resource_id = "/subscriptions/66666666-6666-6666-6666-666666666666/resourceGroups/rg-hub/providers/Microsoft.Network/virtualNetworks/vnet-hub-eastus"

networking_pdz_blob      = "/subscriptions/66666666-6666-6666-6666-666666666666/resourceGroups/rg-hub-dns/providers/Microsoft.Network/privateDnsZones/privatelink.blob.core.windows.net"
networking_pdz_vaultcore = "/subscriptions/66666666-6666-6666-6666-666666666666/resourceGroups/rg-hub-dns/providers/Microsoft.Network/privateDnsZones/privatelink.vaultcore.azure.net"
networking_pdz_azurecr   = "/subscriptions/66666666-6666-6666-6666-666666666666/resourceGroups/rg-hub-dns/providers/Microsoft.Network/privateDnsZones/privatelink.azurecr.io"
networking_pdz_grafana   = "/subscriptions/66666666-6666-6666-6666-666666666666/resourceGroups/rg-hub-dns/providers/Microsoft.Network/privateDnsZones/privatelink.grafana.azure.com"

networking_mgmt_address_space               = "10.50.0.0/20"
networking_env_mgmt_eastus_address_space    = "10.60.0.0/20"
networking_env_nonprod_eastus_address_space = "10.70.0.0/20"
networking_env_prod_eastus_address_space    = "10.80.0.0/20"

# Pod-CIDR slots (0..15, unique per env-region; /12 inside 100.64.0.0/10).
networking_env_mgmt_eastus_pod_cidr_slot    = 0
networking_env_nonprod_eastus_pod_cidr_slot = 1
networking_env_prod_eastus_pod_cidr_slot    = 2
