# fleet-identity unit tests.
#
# Pure-function module (no providers), so these are all zero-side-effect
# `command = apply` runs using `variables { fleet_doc = {...} }`. The
# fixture shapes below mirror PLAN §3.1 (post-143d18b rework: uniform
# per-(env, region) networking; no `fleet.primary_region`; no
# `networking.vnets.mgmt`; no `networking.hubs` map — hub refs live
# on `networking.envs.<env>.regions.<region>.hub_network_resource_id`;
# mgmt is an env with its own regions entry).

# ---- happy path: names, defaults, KV location fallback ---------------------

run "defaults_derive_names_per_naming_contract" {
  command = apply

  variables {
    fleet_doc = {
      fleet = {
        name      = "acme"
        tenant_id = "11111111-1111-1111-1111-111111111111"
      }
      acr = {
        name_override   = ""
        resource_group  = "rg-fleet-shared"
        subscription_id = "22222222-2222-2222-2222-222222222222"
        location        = "eastus"
      }
      keyvault = { name_override = "" }
      state = {
        storage_account_name_override = ""
        resource_group                = "rg-fleet-tfstate"
        subscription_id               = "22222222-2222-2222-2222-222222222222"
        containers                    = { fleet = "tfstate-fleet" }
      }
      envs = {
        mgmt = {
          subscription_id = "33333333-3333-3333-3333-333333333333"
          location        = "eastus"
        }
      }
    }
  }

  assert {
    condition     = output.derived.state_storage_account == "stacmetfstate"
    error_message = "State SA default derivation must be `st<fleet.name>tfstate`."
  }

  assert {
    condition     = output.derived.acr_name == "acracmeshared"
    error_message = "ACR default derivation must be `acr<fleet.name>shared`."
  }

  assert {
    condition     = output.derived.fleet_kv_name == "kv-acme-fleet"
    error_message = "Fleet KV default derivation must be `kv-<fleet.name>-fleet`."
  }

  assert {
    condition     = output.derived.state_container == "tfstate-fleet"
    error_message = "Fleet state container must pass through from state.containers.fleet."
  }

  assert {
    condition     = output.derived.fleet_kv_resource_group == "rg-fleet-shared"
    error_message = "Fleet KV must default its RG to acr.resource_group when keyvault.resource_group is absent."
  }

  assert {
    condition     = output.derived.fleet_kv_location == "eastus"
    error_message = "Fleet KV must default its location to envs.mgmt.location when keyvault.location is absent."
  }

  # All networking_central.* default to null when no networking block.
  assert {
    condition = alltrue([
      output.networking_central.pdz_blob == null,
      output.networking_central.pdz_vaultcore == null,
      output.networking_central.pdz_azurecr == null,
      output.networking_central.pdz_grafana == null,
    ])
    error_message = "networking_central.* must be null when fleet_doc.networking is absent."
  }

  assert {
    condition     = output.networking_derived.envs == {}
    error_message = "networking_derived.envs must be empty when networking.envs is absent."
  }

  assert {
    condition     = output.github_app_fleet_runners.private_key_kv_secret == "fleet-runners-app-pem"
    error_message = "fleet-runners private_key_kv_secret must default to `fleet-runners-app-pem` when absent."
  }
}

# ---- override path: explicit names win over formulas -----------------------

run "overrides_bypass_formulas" {
  command = apply

  variables {
    fleet_doc = {
      fleet = {
        name      = "acme"
        tenant_id = "11111111-1111-1111-1111-111111111111"
      }
      acr = {
        name_override   = "myfleetregistry"
        resource_group  = "rg-custom-acr"
        subscription_id = "22222222-2222-2222-2222-222222222222"
        location        = "westeurope"
      }
      keyvault = {
        name_override  = "kv-custom-name"
        resource_group = "rg-custom-kv"
        location       = "westus2"
      }
      state = {
        storage_account_name_override = "stcustomstate"
        resource_group                = "rg-custom-state"
        subscription_id               = "22222222-2222-2222-2222-222222222222"
        containers                    = { fleet = "tfstate-fleet" }
      }
      envs = {
        mgmt = { subscription_id = "x", location = "eastus" }
      }
    }
  }

  assert {
    condition     = output.derived.state_storage_account == "stcustomstate"
    error_message = "state.storage_account_name_override must bypass the default formula."
  }

  assert {
    condition     = output.derived.acr_name == "myfleetregistry"
    error_message = "acr.name_override must bypass the default formula."
  }

  assert {
    condition     = output.derived.fleet_kv_name == "kv-custom-name"
    error_message = "keyvault.name_override must bypass the default formula."
  }

  assert {
    condition     = output.derived.fleet_kv_resource_group == "rg-custom-kv"
    error_message = "keyvault.resource_group must be honored when set."
  }

  assert {
    condition     = output.derived.fleet_kv_location == "westus2"
    error_message = "keyvault.location must be honored when set."
  }
}

# ---- truncation: 24-char ceiling on KV + SA --------------------------------

run "truncation_enforces_24_char_ceiling" {
  command = apply

  variables {
    fleet_doc = {
      fleet = {
        # 20 chars — wider than the current validator allows. Defense
        # in depth against silent over-limit names.
        name      = "verylongfleetnameabc"
        tenant_id = "11111111-1111-1111-1111-111111111111"
      }
      acr = {
        name_override   = ""
        resource_group  = "rg-fleet-shared"
        subscription_id = "22222222-2222-2222-2222-222222222222"
        location        = "eastus"
      }
      keyvault = { name_override = "" }
      state = {
        storage_account_name_override = ""
        resource_group                = "rg-fleet-tfstate"
        subscription_id               = "22222222-2222-2222-2222-222222222222"
        containers                    = { fleet = "tfstate-fleet" }
      }
      envs = { mgmt = { location = "eastus" } }
    }
  }

  assert {
    condition     = length(output.derived.state_storage_account) <= 24
    error_message = "State SA name must be ≤ 24 chars after truncation."
  }

  assert {
    condition     = length(output.derived.fleet_kv_name) <= 24
    error_message = "Fleet KV name must be ≤ 24 chars after truncation."
  }

  assert {
    condition     = startswith(output.derived.state_storage_account, "stverylongfleet")
    error_message = "State SA truncation must keep the prefix `st<name>…`."
  }

  assert {
    condition     = startswith(output.derived.fleet_kv_name, "kv-verylongfleet")
    error_message = "Fleet KV truncation must keep the prefix `kv-<name>…`."
  }
}

# ---- networking_central passthrough: values exposed verbatim when present --

run "networking_central_passthrough_when_populated" {
  command = apply

  variables {
    fleet_doc = {
      fleet = {
        name      = "acme"
        tenant_id = "11111111-1111-1111-1111-111111111111"
      }
      acr = {
        name_override   = ""
        resource_group  = "rg-fleet-shared"
        subscription_id = "22222222-2222-2222-2222-222222222222"
        location        = "eastus"
      }
      keyvault = { name_override = "" }
      state = {
        storage_account_name_override = ""
        resource_group                = "rg-fleet-tfstate"
        subscription_id               = "22222222-2222-2222-2222-222222222222"
        containers                    = { fleet = "tfstate-fleet" }
      }
      envs = { mgmt = { location = "eastus" } }
      networking = {
        envs = {
          mgmt = {
            regions = {
              eastus = {
                address_space           = ["10.50.0.0/20"]
                hub_network_resource_id = "/subscriptions/hhh/resourceGroups/rg-hub/providers/Microsoft.Network/virtualNetworks/vnet-hub-mgmt-eastus"
              }
            }
          }
          nonprod = {
            regions = {
              eastus = {
                address_space           = ["10.60.0.0/20"]
                hub_network_resource_id = "/subscriptions/hhh/resourceGroups/rg-hub/providers/Microsoft.Network/virtualNetworks/vnet-hub-nonprod-eastus"
              }
            }
          }
          prod = {
            regions = {
              eastus = {
                address_space           = ["10.70.0.0/20"]
                hub_network_resource_id = "/subscriptions/hhh/resourceGroups/rg-hub/providers/Microsoft.Network/virtualNetworks/vnet-hub-prod-eastus"
              }
            }
          }
        }
        private_dns_zones = {
          blob      = "/subscriptions/hhh/resourceGroups/rg-dns/providers/Microsoft.Network/privateDnsZones/privatelink.blob.core.windows.net"
          vaultcore = "/subscriptions/hhh/resourceGroups/rg-dns/providers/Microsoft.Network/privateDnsZones/privatelink.vaultcore.azure.net"
          azurecr   = "/subscriptions/hhh/resourceGroups/rg-dns/providers/Microsoft.Network/privateDnsZones/privatelink.azurecr.io"
          grafana   = "/subscriptions/hhh/resourceGroups/rg-dns/providers/Microsoft.Network/privateDnsZones/privatelink.grafana.azure.com"
        }
      }
      github_app = {
        fleet_runners = {
          app_id                = "1234567"
          installation_id       = "7654321"
          private_key_kv_secret = "my-custom-pem"
        }
      }
    }
  }

  assert {
    condition     = endswith(output.networking_derived.envs["nonprod/eastus"].hub_network_resource_id, "/virtualNetworks/vnet-hub-nonprod-eastus")
    error_message = "networking.envs.<env>.regions.<region>.hub_network_resource_id must pass through on networking_derived.envs[\"<env>/<region>\"].hub_network_resource_id."
  }

  assert {
    condition     = endswith(output.networking_derived.envs["mgmt/eastus"].hub_network_resource_id, "/virtualNetworks/vnet-hub-mgmt-eastus")
    error_message = "mgmt env-regions carry hub_network_resource_id too (mgmt↔hub peering owned by bootstrap/fleet)."
  }

  assert {
    condition     = endswith(output.networking_derived.envs["prod/eastus"].hub_network_resource_id, "/virtualNetworks/vnet-hub-prod-eastus")
    error_message = "Every (env, region) hub reference must pass through verbatim."
  }

  assert {
    condition     = endswith(output.networking_central.pdz_blob, "privatelink.blob.core.windows.net")
    error_message = "networking.private_dns_zones.blob must pass through verbatim."
  }

  assert {
    condition     = output.networking_central.pdz_vaultcore != null && output.networking_central.pdz_azurecr != null && output.networking_central.pdz_grafana != null
    error_message = "All four private_dns_zones.* must pass through when populated."
  }

  assert {
    condition     = output.github_app_fleet_runners.private_key_kv_secret == "my-custom-pem"
    error_message = "github_app.fleet_runners.private_key_kv_secret must honor an explicit value."
  }

  assert {
    condition     = output.github_app_fleet_runners.app_id == "1234567"
    error_message = "github_app.fleet_runners.app_id must pass through when set."
  }
}

# ---- networking_derived: /20 topology produces expected names + CIDRs ------
#
# Canonical PLAN §3.4 layout. Mgmt env-region eastus 10.50.0.0/20,
# nonprod env-region eastus 10.60.0.0/20. Assert:
#   - uniform vnet/rg/route-table/ASG names (both mgmt and nonprod)
#   - cluster-workload subnet (snet-pe-env) on both VNets
#   - fleet-plane subnets (snet-pe-fleet, snet-runners) ONLY on mgmt
#   - peering names present on nonprod; null on mgmt (mgmt doesn't peer
#     itself from env state)
#   - cluster_slot_capacity = 16 at /20

run "networking_derived_populates_topology_at_slash20" {
  command = apply

  variables {
    fleet_doc = {
      fleet = {
        name      = "acme"
        tenant_id = "11111111-1111-1111-1111-111111111111"
      }
      acr = {
        name_override   = ""
        resource_group  = "rg-fleet-shared"
        subscription_id = "22222222-2222-2222-2222-222222222222"
        location        = "eastus"
      }
      keyvault = { name_override = "" }
      state = {
        storage_account_name_override = ""
        resource_group                = "rg-fleet-tfstate"
        subscription_id               = "22222222-2222-2222-2222-222222222222"
        containers                    = { fleet = "tfstate-fleet" }
      }
      envs = { mgmt = { location = "eastus" } }
      networking = {
        envs = {
          mgmt = {
            regions = {
              eastus = {
                address_space          = ["10.50.0.0/20"]
                create_reverse_peering = true
              }
            }
          }
          nonprod = {
            regions = {
              eastus = {
                address_space          = ["10.60.0.0/20"]
                create_reverse_peering = true
              }
            }
          }
        }
      }
    }
  }

  # --- mgmt env-region ---
  assert {
    condition     = output.networking_derived.envs["mgmt/eastus"].vnet_name == "vnet-acme-mgmt-eastus"
    error_message = "mgmt VNet name must be `vnet-<fleet>-mgmt-<region>` (uniform with other envs)."
  }

  assert {
    condition     = output.networking_derived.envs["mgmt/eastus"].rg_name == "rg-net-mgmt-eastus"
    error_message = "mgmt VNet RG must be `rg-net-mgmt-<region>` (uniform with other envs)."
  }

  assert {
    condition     = output.networking_derived.envs["mgmt/eastus"].cidr == "10.50.0.0/20"
    error_message = "mgmt address_space first entry must pass through as `cidr`."
  }

  assert {
    condition     = output.networking_derived.envs["mgmt/eastus"].snet_pe_env_cidr == "10.50.0.0/26"
    error_message = "mgmt snet-pe-env must be the first /26 of the first /24 of the VNet (cluster-workload zone)."
  }

  assert {
    condition     = output.networking_derived.envs["mgmt/eastus"].snet_runners_cidr == "10.50.8.0/23"
    error_message = "mgmt snet-runners must be the first /23 of the upper-/21 fleet zone (PLAN §3.4 L704)."
  }

  assert {
    condition     = output.networking_derived.envs["mgmt/eastus"].snet_pe_fleet_cidr == "10.50.10.0/26"
    error_message = "mgmt snet-pe-fleet must be the /26 at index 8 of the fleet zone = 10.50.10.0/26 (PLAN §3.4 L705)."
  }

  assert {
    condition     = output.networking_derived.envs["mgmt/eastus"].route_table_name == "rt-aks-mgmt-eastus"
    error_message = "route_table_name must be `rt-aks-<env>-<region>`."
  }

  assert {
    condition     = output.networking_derived.envs["mgmt/eastus"].peering_spoke_to_mgmt_name == null
    error_message = "mgmt env-regions do not author env-state spoke→mgmt peering; name must be null."
  }

  assert {
    condition     = output.networking_derived.envs["mgmt/eastus"].hub_network_resource_id == null
    error_message = "mgmt env-region hub_network_resource_id must default to null when fixture omits it."
  }

  assert {
    condition     = output.networking_derived.envs["mgmt/eastus"].nsg_pe_fleet_name == "nsg-pe-fleet-eastus"
    error_message = "Fleet-plane PE NSG must be `nsg-pe-fleet-<region>`."
  }

  # --- nonprod env-region ---
  assert {
    condition     = output.networking_derived.envs["nonprod/eastus"].vnet_name == "vnet-acme-nonprod-eastus"
    error_message = "nonprod VNet name must be `vnet-<fleet>-<env>-<region>`."
  }

  assert {
    condition     = output.networking_derived.envs["nonprod/eastus"].rg_name == "rg-net-nonprod-eastus"
    error_message = "nonprod VNet RG must be `rg-net-<env>-<region>`."
  }

  assert {
    condition     = output.networking_derived.envs["nonprod/eastus"].snet_pe_env_cidr == "10.60.0.0/26"
    error_message = "nonprod snet-pe-env must be the first /26 of the cluster-workload zone."
  }

  assert {
    condition     = output.networking_derived.envs["nonprod/eastus"].snet_pe_fleet_cidr == null
    error_message = "Non-mgmt env-regions must NOT carry snet-pe-fleet."
  }

  assert {
    condition     = output.networking_derived.envs["nonprod/eastus"].snet_runners_cidr == null
    error_message = "Non-mgmt env-regions must NOT carry snet-runners."
  }

  assert {
    condition     = output.networking_derived.envs["nonprod/eastus"].cluster_slot_capacity == 16
    error_message = "A /20 env VNet must yield 16 usable cluster slots under the two-pool layout."
  }

  assert {
    condition     = output.networking_derived.envs["nonprod/eastus"].peering_spoke_to_mgmt_name == "peer-nonprod-eastus-to-mgmt-eastus"
    error_message = "spoke→mgmt peering name must be `peer-<env>-<region>-to-mgmt-<mgmt-region>` (PLAN §3.3 new table)."
  }

  assert {
    condition     = output.networking_derived.envs["nonprod/eastus"].peering_mgmt_to_spoke_name == "peer-mgmt-eastus-to-nonprod-eastus"
    error_message = "mgmt→spoke peering name must be `peer-mgmt-<mgmt-region>-to-<env>-<region>` (PLAN §3.3 new table)."
  }

  assert {
    condition     = output.networking_derived.envs["nonprod/eastus"].node_asg_name == "asg-nodes-nonprod-eastus"
    error_message = "env-region node ASG name must be `asg-nodes-<env>-<region>`."
  }

  assert {
    condition     = output.networking_derived.envs["nonprod/eastus"].nsg_pe_env_name == "nsg-pe-env-nonprod-eastus"
    error_message = "env PE NSG name must be `nsg-pe-env-<env>-<region>`."
  }

  assert {
    condition     = output.networking_derived.envs["nonprod/eastus"].create_reverse_peering == true
    error_message = "create_reverse_peering default must pass through as true."
  }

  assert {
    condition     = output.networking_derived.envs["nonprod/eastus"].egress_next_hop_ip == null
    error_message = "egress_next_hop_ip must default to null when absent from fleet_doc."
  }

  # --- F6 hub-and-spoke knobs: defaults preserve pre-F6 behaviour ---
  assert {
    condition     = output.networking_derived.envs["mgmt/eastus"].use_remote_gateways == false
    error_message = "use_remote_gateways must default to false (preserves pre-F6 no-gateway-transit behaviour)."
  }

  assert {
    condition     = output.networking_derived.envs["mgmt/eastus"].dns_servers == tolist([])
    error_message = "dns_servers must default to [] (Azure-provided DNS)."
  }

  assert {
    condition     = output.networking_derived.envs["mgmt/eastus"].subnet_route_table_ids == tomap({})
    error_message = "subnet_route_table_ids must default to {} (no per-subnet RT override)."
  }

  assert {
    condition     = output.networking_derived.envs["mgmt/eastus"].rt_fleet_name == "rt-fleet-eastus"
    error_message = "rt_fleet_name must be `rt-fleet-<region>` on mgmt env-regions (fleet-plane RT when egress_next_hop_ip is set)."
  }

  assert {
    condition     = output.networking_derived.envs["nonprod/eastus"].rt_fleet_name == null
    error_message = "rt_fleet_name must be null on non-mgmt env-regions (cluster-plane RT is rt-aks-<env>-<region>)."
  }

  assert {
    condition     = output.networking_derived.envs["nonprod/eastus"].use_remote_gateways == false
    error_message = "use_remote_gateways must default to false on non-mgmt env-regions too."
  }
}

# ---- networking_derived: create_reverse_peering = false honored ------------

run "networking_derived_honors_create_reverse_peering_false" {
  command = apply

  variables {
    fleet_doc = {
      fleet = {
        name      = "acme"
        tenant_id = "11111111-1111-1111-1111-111111111111"
      }
      acr = {
        name_override   = ""
        resource_group  = "rg-fleet-shared"
        subscription_id = "22222222-2222-2222-2222-222222222222"
        location        = "eastus"
      }
      keyvault = { name_override = "" }
      state = {
        storage_account_name_override = ""
        resource_group                = "rg-fleet-tfstate"
        subscription_id               = "22222222-2222-2222-2222-222222222222"
        containers                    = { fleet = "tfstate-fleet" }
      }
      envs = { mgmt = { location = "eastus" } }
      networking = {
        envs = {
          mgmt = {
            regions = {
              eastus = { address_space = ["10.50.0.0/20"] }
            }
          }
          prod = {
            regions = {
              eastus = {
                address_space          = ["10.70.0.0/20"]
                create_reverse_peering = false
                egress_next_hop_ip     = "10.0.0.4"
              }
            }
          }
        }
      }
    }
  }

  assert {
    condition     = output.networking_derived.envs["prod/eastus"].create_reverse_peering == false
    error_message = "create_reverse_peering = false must pass through for downstream gating of reverse-half authoring."
  }

  assert {
    condition     = output.networking_derived.envs["prod/eastus"].egress_next_hop_ip == "10.0.0.4"
    error_message = "egress_next_hop_ip must pass through verbatim; bootstrap/environment gates route-entry creation on non-null."
  }

  # Name is still derived (Stage -1 uses create_reverse_peering to
  # decide whether to author the reverse resource, not whether to
  # name it).
  assert {
    condition     = output.networking_derived.envs["prod/eastus"].peering_mgmt_to_spoke_name == "peer-mgmt-eastus-to-prod-eastus"
    error_message = "peering_mgmt_to_spoke_name is always derived; reverse-half creation is gated separately."
  }
}

# ---- networking_derived: multi-env + multi-region flatten correctly --------

run "networking_derived_flattens_multi_env_multi_region" {
  command = apply

  variables {
    fleet_doc = {
      fleet = {
        name      = "acme"
        tenant_id = "11111111-1111-1111-1111-111111111111"
      }
      acr = {
        name_override   = ""
        resource_group  = "rg-fleet-shared"
        subscription_id = "22222222-2222-2222-2222-222222222222"
        location        = "eastus"
      }
      keyvault = { name_override = "" }
      state = {
        storage_account_name_override = ""
        resource_group                = "rg-fleet-tfstate"
        subscription_id               = "22222222-2222-2222-2222-222222222222"
        containers                    = { fleet = "tfstate-fleet" }
      }
      envs = { mgmt = { location = "eastus" } }
      networking = {
        envs = {
          mgmt = {
            regions = {
              eastus = { address_space = ["10.50.0.0/20"] }
            }
          }
          nonprod = {
            regions = {
              eastus  = { address_space = ["10.60.0.0/20"] }
              westus2 = { address_space = ["10.61.0.0/20"] }
            }
          }
          prod = {
            regions = {
              eastus = { address_space = ["10.70.0.0/20"] }
            }
          }
        }
      }
    }
  }

  assert {
    condition     = length(keys(output.networking_derived.envs)) == 4
    error_message = "Flattened envs map must contain one entry per (env, region) pair (mgmt+nonprod/eastus+nonprod/westus2+prod/eastus)."
  }

  assert {
    condition = alltrue([
      contains(keys(output.networking_derived.envs), "mgmt/eastus"),
      contains(keys(output.networking_derived.envs), "nonprod/eastus"),
      contains(keys(output.networking_derived.envs), "nonprod/westus2"),
      contains(keys(output.networking_derived.envs), "prod/eastus"),
    ])
    error_message = "Flattened envs map keys must be `<env>/<region>` for every (env, region) pair including mgmt."
  }

  assert {
    condition     = output.networking_derived.envs["nonprod/westus2"].vnet_name == "vnet-acme-nonprod-westus2"
    error_message = "Second region of an env must derive its own VNet name."
  }

  assert {
    condition     = output.networking_derived.envs["prod/eastus"].peering_spoke_to_mgmt_name == "peer-prod-eastus-to-mgmt-eastus"
    error_message = "Prod env-region peering names must not collide with nonprod."
  }

  # nonprod/westus2 has no matching mgmt region: falls back to first
  # mgmt region (mgmt/eastus). Names still derive, pointing cross-region.
  assert {
    condition     = output.networking_derived.envs["nonprod/westus2"].peering_spoke_to_mgmt_name == "peer-nonprod-westus2-to-mgmt-eastus"
    error_message = "spoke→mgmt peering must resolve to the (single) mgmt region when the spoke region has no same-region mgmt entry."
  }
}

# ---- networking_derived: two-pool capacity ---------------------------------
#
# Two-pool layout: capacity = min(16, 2 * (2^(24-N) - 2)).
# /19 → min(16, 2 * 30) = 16   (still api-pool-bound)
# /21 → min(16, 2 * 6)  = 12
# /22 → min(16, 2 * 2)  = 4

run "networking_derived_capacity_two_pool" {
  command = apply

  variables {
    fleet_doc = {
      fleet = {
        name      = "acme"
        tenant_id = "11111111-1111-1111-1111-111111111111"
      }
      acr = {
        name_override   = ""
        resource_group  = "rg-fleet-shared"
        subscription_id = "22222222-2222-2222-2222-222222222222"
        location        = "eastus"
      }
      keyvault = { name_override = "" }
      state = {
        storage_account_name_override = ""
        resource_group                = "rg-fleet-tfstate"
        subscription_id               = "22222222-2222-2222-2222-222222222222"
        containers                    = { fleet = "tfstate-fleet" }
      }
      envs = { mgmt = { location = "eastus" } }
      networking = {
        envs = {
          mgmt = {
            regions = {
              eastus = { address_space = ["10.10.0.0/19"] }
            }
          }
          nonprod = {
            regions = {
              eastus = { address_space = ["10.20.0.0/21"] }
            }
          }
          prod = {
            regions = {
              eastus = { address_space = ["10.30.0.0/22"] }
            }
          }
        }
      }
    }
  }

  assert {
    condition     = output.networking_derived.envs["mgmt/eastus"].cluster_slot_capacity == 16
    error_message = "A /19 VNet must cap at 16 usable cluster slots (api-pool-bound) under the two-pool layout."
  }

  assert {
    condition     = output.networking_derived.envs["nonprod/eastus"].cluster_slot_capacity == 12
    error_message = "A /21 env VNet must yield 12 usable cluster slots under the two-pool layout (min(16, 2*6))."
  }

  assert {
    condition     = output.networking_derived.envs["prod/eastus"].cluster_slot_capacity == 4
    error_message = "A /22 env VNet must yield 4 usable cluster slots under the two-pool layout (min(16, 2*2))."
  }

  # snet-pe-env is still the first /26 of the first /24 of A regardless
  # of VNet size.
  assert {
    condition     = output.networking_derived.envs["mgmt/eastus"].snet_pe_env_cidr == "10.10.0.0/26"
    error_message = "snet-pe-env must be the first /26 of A regardless of VNet size."
  }
}

# ---- networking_derived: F6 hub-and-spoke knobs pass through ---------------
#
# All three fields are optional on `_fleet.yaml` and default to the
# pre-F6 "island VNet" behaviour (see defaults assertions in
# `networking_derived_populates_topology_at_slash20`). When set,
# `use_remote_gateways` / `dns_servers` / `subnet_route_table_ids` pass
# through verbatim to `networking_derived.envs.<env>/<region>` for
# consumption by `bootstrap/fleet` + `bootstrap/environment`.

run "networking_derived_surfaces_f6_hub_spoke_knobs" {
  command = apply

  variables {
    fleet_doc = {
      fleet = {
        name      = "acme"
        tenant_id = "11111111-1111-1111-1111-111111111111"
      }
      acr = {
        name_override   = ""
        resource_group  = "rg-fleet-shared"
        subscription_id = "22222222-2222-2222-2222-222222222222"
        location        = "eastus"
      }
      keyvault = { name_override = "" }
      state = {
        storage_account_name_override = ""
        resource_group                = "rg-fleet-tfstate"
        subscription_id               = "22222222-2222-2222-2222-222222222222"
        containers                    = { fleet = "tfstate-fleet" }
      }
      envs = { mgmt = { location = "eastus" } }
      networking = {
        envs = {
          mgmt = {
            regions = {
              eastus = {
                address_space           = ["10.50.0.0/20"]
                hub_network_resource_id = "/subscriptions/hhh/resourceGroups/rg-hub/providers/Microsoft.Network/virtualNetworks/vnet-hub-mgmt-eastus"
                hub_peering = {
                  use_remote_gateways = true
                }
                dns_servers = ["10.0.0.4", "10.0.0.5"]
                subnet_route_table_ids = {
                  pe-fleet = "/subscriptions/hhh/resourceGroups/rg-hub/providers/Microsoft.Network/routeTables/rt-hub-mgmt-eastus"
                  runners  = "/subscriptions/hhh/resourceGroups/rg-hub/providers/Microsoft.Network/routeTables/rt-hub-mgmt-eastus"
                }
              }
            }
          }
          nonprod = {
            regions = {
              eastus = {
                address_space      = ["10.60.0.0/20"]
                egress_next_hop_ip = "10.0.0.4"
                subnet_route_table_ids = {
                  pe-env = "/subscriptions/hhh/resourceGroups/rg-hub/providers/Microsoft.Network/routeTables/rt-hub-nonprod-eastus"
                }
              }
            }
          }
        }
      }
    }
  }

  # --- mgmt: all three knobs flow through ---
  assert {
    condition     = output.networking_derived.envs["mgmt/eastus"].use_remote_gateways == true
    error_message = "hub_peering.use_remote_gateways on a region must pass through as networking_derived.envs.<k>.use_remote_gateways."
  }

  assert {
    condition     = output.networking_derived.envs["mgmt/eastus"].dns_servers == tolist(["10.0.0.4", "10.0.0.5"])
    error_message = "dns_servers must pass through verbatim on networking_derived.envs.<k>.dns_servers."
  }

  assert {
    condition = (
      output.networking_derived.envs["mgmt/eastus"].subnet_route_table_ids["pe-fleet"] ==
      "/subscriptions/hhh/resourceGroups/rg-hub/providers/Microsoft.Network/routeTables/rt-hub-mgmt-eastus"
    )
    error_message = "subnet_route_table_ids.pe-fleet must pass through verbatim."
  }

  assert {
    condition = (
      output.networking_derived.envs["mgmt/eastus"].subnet_route_table_ids["runners"] ==
      "/subscriptions/hhh/resourceGroups/rg-hub/providers/Microsoft.Network/routeTables/rt-hub-mgmt-eastus"
    )
    error_message = "subnet_route_table_ids.runners must pass through verbatim."
  }

  # --- non-mgmt: pe-env override + egress_next_hop_ip coexist ---
  assert {
    condition = (
      output.networking_derived.envs["nonprod/eastus"].subnet_route_table_ids["pe-env"] ==
      "/subscriptions/hhh/resourceGroups/rg-hub/providers/Microsoft.Network/routeTables/rt-hub-nonprod-eastus"
    )
    error_message = "subnet_route_table_ids.pe-env must pass through on non-mgmt env-regions."
  }

  assert {
    condition     = output.networking_derived.envs["nonprod/eastus"].egress_next_hop_ip == "10.0.0.4"
    error_message = "egress_next_hop_ip must coexist with subnet_route_table_ids (override precedence is a call-site concern, not a derivation concern)."
  }

  # --- defaults still hold on fields not set ---
  assert {
    condition     = output.networking_derived.envs["nonprod/eastus"].use_remote_gateways == false
    error_message = "use_remote_gateways must default to false when hub_peering is not set on this region."
  }

  assert {
    condition     = output.networking_derived.envs["nonprod/eastus"].dns_servers == tolist([])
    error_message = "dns_servers must default to [] when not set on this region."
  }
}
