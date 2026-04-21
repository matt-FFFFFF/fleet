output "fleet" {
  description = "Passthrough of `fleet_doc.fleet` (name, tenant_id, etc.)."
  value       = local.fleet
}

output "envs" {
  description = "Passthrough of `fleet_doc.envs` (per-env subscription_id, AAD bindings, mgmt.location, etc.)."
  value       = local.envs
}

output "derived" {
  description = "Derived names per docs/naming.md."
  value       = local.derived
}

output "networking_central" {
  description = <<-EOT
    Adopter-BYO central networking (PLAN §3.1 / §3.4):

      hubs          = { "<env>/<region>" = <hub-vnet-resource-id> }
      pdz_blob      = <privatelink.blob... zone id>
      pdz_vaultcore = <privatelink.vaultcore... zone id>
      pdz_azurecr   = <privatelink.azurecr... zone id>
      pdz_grafana   = <privatelink.grafana... zone id>

    `hubs` is an empty map when `networking.hubs` is absent. The four
    PDZ ids may each be null when absent. Downstream callsites
    precondition non-null.
  EOT
  value       = local.networking_central
}

output "networking_derived" {
  description = <<-EOT
    Repo-owned VNet topology derivations (PLAN §3.4). Uniform shape
    across every env including mgmt:

      envs = {
        "<env>/<region>" = {
          env, region, location, address_space, cidr,
          vnet_name, rg_name,
          snet_pe_env_cidr, cluster_slot_capacity,
          node_asg_name, nsg_pe_env_name, route_table_name,
          peering_spoke_to_mgmt_name,    # null when env == "mgmt"
          peering_mgmt_to_spoke_name,    # null when env == "mgmt"
          create_reverse_peering,
          mgmt_environment_for_vnet_peering,
          egress_next_hop_ip,            # null unless adopter filled it
          # mgmt-only fleet-plane fields; null for non-mgmt:
          snet_pe_fleet_cidr, snet_runners_cidr,
          nsg_pe_fleet_name, nsg_runners_name
        }
      }

    `envs` is an empty map when `networking.envs` is absent. Individual
    CIDR fields are null when the corresponding `address_space` is
    absent or malformed.

    Cluster-scope per-slot `/28` api + `/25` nodes CIDRs are NOT
    emitted here — they live in `config-loader/load.sh` and Stage 1,
    which have cluster identity as input. Pod IPs use a shared CGNAT
    /16 (`100.64.0.0/16`) hard-coded in `modules/aks-cluster/main.tf`;
    see PLAN §3.4. Parity contract: docs/naming.md.
  EOT
  value       = local.networking_derived
}

output "github_app_fleet_runners" {
  description = "fleet-runners GH App coordinates (app_id, installation_id, private_key_kv_secret)."
  value       = local.github_app_fleet_runners
}
