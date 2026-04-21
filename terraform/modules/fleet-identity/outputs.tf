output "fleet" {
  description = "Passthrough of `fleet_doc.fleet` (name, tenant_id, etc.)."
  value       = local.fleet
}

output "derived" {
  description = "Derived names per docs/naming.md."
  value       = local.derived
}

output "networking_central" {
  description = "Adopter-BYO central networking: hub VNet resource id + four `privatelink.*` private DNS zone ids (blob, vaultcore, azurecr, grafana). Values may be null when absent from `_fleet.yaml`; downstream callsites precondition non-null."
  value       = local.networking_central
}

output "networking_derived" {
  description = <<-EOT
    Repo-owned VNet topology derivations (PLAN §3.4). Shape:

      mgmt = null | {
        vnet_name, rg_name, address_space, location,
        snet_pe_shared_cidr, snet_runners_cidr, cluster_slot_capacity
      }
      envs = {
        "<env>/<region>" = {
          env, region, location, address_space,
          vnet_name, rg_name,
          snet_pe_env_cidr, cluster_slot_capacity,
          peering_env_to_mgmt_name, peering_mgmt_to_env_name,
          node_asg_name, nsg_pe_name
        }
      }

    `mgmt` is null when `networking.vnets.mgmt` is absent; `envs` is an
    empty map when `networking.envs` is absent. Individual CIDR fields
    are null when the corresponding `address_space` is absent.

    Cluster-scope per-slot `/28` api + `/25` nodes CIDRs are NOT emitted
    here — they live in `config-loader/load.sh` and Stage 1, which have
    cluster identity as input. Pod IPs use a shared CGNAT /16
    (`100.64.0.0/16`) hard-coded in `modules/aks-cluster/main.tf`; see
    PLAN §3.4 Implementation status for rationale. Parity contract:
    docs/naming.md.
  EOT
  value       = local.networking_derived
}

output "github_app_fleet_runners" {
  description = "fleet-runners GH App coordinates (app_id, installation_id, private_key_kv_secret)."
  value       = local.github_app_fleet_runners
}
