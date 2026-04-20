# fleet-identity unit tests.
#
# Pure-function module (no providers), so these are all zero-side-effect
# `command = apply` runs using `variables { fleet_doc = {...} }`. The
# fixture shapes below mirror what `init/templates/_fleet.yaml.tftpl`
# produces plus the overrides adopters are expected to set.

# ---- happy path: canonical selftest fixture --------------------------------

run "defaults_derive_names_per_naming_contract" {
  command = apply

  variables {
    fleet_doc = {
      fleet = {
        name           = "acme"
        primary_region = "eastus"
        tenant_id      = "11111111-1111-1111-1111-111111111111"
      }
      acr = {
        name_override   = ""
        resource_group  = "rg-fleet-shared"
        subscription_id = "22222222-2222-2222-2222-222222222222"
        location        = "eastus"
      }
      keyvault = {
        name_override = ""
      }
      state = {
        storage_account_name_override = ""
        resource_group                = "rg-fleet-tfstate"
        subscription_id               = "22222222-2222-2222-2222-222222222222"
        containers                    = { fleet = "tfstate-fleet" }
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
    error_message = "Fleet KV must default its location to fleet.primary_region when keyvault.location is absent."
  }

  # All networking_central.* default to null when _fleet.yaml has no
  # networking block (PLAN §3.4 post-Phase-B shape).
  assert {
    condition = alltrue([
      output.networking_central.hub_resource_id == null,
      output.networking_central.pdz_blob == null,
      output.networking_central.pdz_vaultcore == null,
      output.networking_central.pdz_azurecr == null,
      output.networking_central.pdz_grafana == null,
    ])
    error_message = "All networking_central.* identifiers must be null when fleet_doc.networking is absent."
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
        name           = "acme"
        primary_region = "eastus"
        tenant_id      = "11111111-1111-1111-1111-111111111111"
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
#
# fleet_name validator caps at 12 chars, so `st<name>tfstate` = 2+12+7 = 21
# and `kv-<name>-fleet` = 3+12+6 = 21 — both fit. This run block verifies
# the substr() guard still behaves even if a future schema relaxation
# widens fleet_name (defense in depth against silent over-limit names).

run "truncation_enforces_24_char_ceiling" {
  command = apply

  variables {
    fleet_doc = {
      fleet = {
        # 20 chars — deliberately wider than the current validator allows.
        name           = "verylongfleetnameabc"
        primary_region = "eastus"
        tenant_id      = "11111111-1111-1111-1111-111111111111"
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

  # Explicit sanity-check on the truncated prefix to catch a broken substr()
  # (e.g. accidentally truncating from the left).
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
        name           = "acme"
        primary_region = "eastus"
        tenant_id      = "11111111-1111-1111-1111-111111111111"
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
      networking = {
        hub = {
          resource_id = "/subscriptions/hhh/resourceGroups/rg-hub/providers/Microsoft.Network/virtualNetworks/vnet-hub-eastus"
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
    condition     = endswith(output.networking_central.hub_resource_id, "/virtualNetworks/vnet-hub-eastus")
    error_message = "networking.hub.resource_id must pass through verbatim."
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

# ---- networking_derived: topology absent → safe nulls ----------------------

run "networking_derived_absent_yields_nulls" {
  command = apply

  variables {
    fleet_doc = {
      fleet = {
        name           = "acme"
        primary_region = "eastus"
        tenant_id      = "11111111-1111-1111-1111-111111111111"
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
    }
  }

  assert {
    condition     = output.networking_derived.mgmt == null
    error_message = "networking_derived.mgmt must be null when networking.vnets.mgmt is absent."
  }

  assert {
    condition     = output.networking_derived.envs == {}
    error_message = "networking_derived.envs must be an empty map when networking.envs is absent."
  }
}

# ---- networking_derived: /20 topology produces expected names + CIDRs ------
#
# Canonical PLAN §3.4 layout. Mgmt VNet 10.10.0.0/20, one env (nonprod)
# with one region (eastus) 10.20.0.0/20. Assert:
#   - mgmt VNet/RG names
#   - mgmt's two reserved /26s (snet-pe-shared first, snet-runners second)
#   - env VNet/RG names, /26 PE subnet, peering names, ASG name
#   - cluster_slot_capacity = 16 at /20 (two-pool layout: min(16, 2 *
#     (2^(24-N) - 2)); api pool is the cap).

run "networking_derived_populates_topology_at_slash20" {
  command = apply

  variables {
    fleet_doc = {
      fleet = {
        name           = "acme"
        primary_region = "eastus"
        tenant_id      = "11111111-1111-1111-1111-111111111111"
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
      networking = {
        vnets = {
          mgmt = {
            location      = "eastus"
            address_space = "10.10.0.0/20"
          }
        }
        envs = {
          nonprod = {
            regions = {
              eastus = {
                address_space = "10.20.0.0/20"
                pod_cidr_slot = 3
              }
            }
          }
        }
      }
    }
  }

  # --- mgmt ---
  assert {
    condition     = output.networking_derived.mgmt.vnet_name == "vnet-acme-mgmt"
    error_message = "mgmt VNet name must be `vnet-<fleet.name>-mgmt`."
  }

  assert {
    condition     = output.networking_derived.mgmt.rg_name == "rg-net-mgmt"
    error_message = "mgmt VNet RG must be `rg-net-mgmt`."
  }

  assert {
    condition     = output.networking_derived.mgmt.address_space == "10.10.0.0/20"
    error_message = "mgmt address_space must pass through verbatim."
  }

  assert {
    condition     = output.networking_derived.mgmt.snet_pe_shared_cidr == "10.10.0.0/26"
    error_message = "mgmt snet-pe-shared must be the first /26 of the VNet."
  }

  assert {
    condition     = output.networking_derived.mgmt.snet_runners_cidr == "10.10.0.64/26"
    error_message = "mgmt snet-runners must be the second /26 of the VNet."
  }

  assert {
    condition     = output.networking_derived.mgmt.cluster_slot_capacity == 16
    error_message = "A /20 VNet must yield 16 usable cluster slots under the two-pool layout (api pool of 16 × /28 is the cap)."
  }

  # --- env ---
  assert {
    condition     = output.networking_derived.envs["nonprod/eastus"].vnet_name == "vnet-acme-nonprod-eastus"
    error_message = "env VNet name must be `vnet-<fleet.name>-<env>-<region>`."
  }

  assert {
    condition     = output.networking_derived.envs["nonprod/eastus"].rg_name == "rg-net-nonprod"
    error_message = "env VNet RG must be `rg-net-<env>`."
  }

  assert {
    condition     = output.networking_derived.envs["nonprod/eastus"].snet_pe_env_cidr == "10.20.0.0/26"
    error_message = "env snet-pe-env must be the first /26 of the env VNet."
  }

  assert {
    condition     = output.networking_derived.envs["nonprod/eastus"].cluster_slot_capacity == 16
    error_message = "A /20 env VNet must yield 16 usable cluster slots under the two-pool layout."
  }

  assert {
    condition     = output.networking_derived.envs["nonprod/eastus"].peering_env_to_mgmt_name == "peer-nonprod-eastus-to-mgmt"
    error_message = "env→mgmt peering name must be `peer-<env>-<region>-to-mgmt`."
  }

  assert {
    condition     = output.networking_derived.envs["nonprod/eastus"].peering_mgmt_to_env_name == "peer-mgmt-to-nonprod-eastus"
    error_message = "mgmt→env peering name must be `peer-mgmt-to-<env>-<region>`."
  }

  assert {
    condition     = output.networking_derived.envs["nonprod/eastus"].node_asg_name == "asg-nodes-nonprod-eastus"
    error_message = "env-region node ASG name must be `asg-nodes-<env>-<region>`."
  }

  assert {
    condition     = output.networking_derived.envs["nonprod/eastus"].nsg_pe_name == "nsg-pe-env-nonprod-eastus"
    error_message = "env PE NSG name must be `nsg-pe-env-<env>-<region>`."
  }

  assert {
    condition     = output.networking_derived.envs["nonprod/eastus"].location == "eastus"
    error_message = "env location must default to the region name when not explicitly set."
  }

  # --- CGNAT pod CIDR passthrough + envelope derivation ---
  assert {
    condition     = output.networking_derived.envs["nonprod/eastus"].pod_cidr_slot == 3
    error_message = "pod_cidr_slot must pass through verbatim from the region block."
  }

  assert {
    condition     = output.networking_derived.envs["nonprod/eastus"].pod_cidr_envelope == "100.112.0.0/12"
    error_message = "pod_cidr_envelope for slot=3 must be 100.[64+3*16=112].0.0/12."
  }
}

# ---- networking_derived: multi-env + multi-region flatten correctly --------

run "networking_derived_flattens_multi_env_multi_region" {
  command = apply

  variables {
    fleet_doc = {
      fleet = {
        name           = "acme"
        primary_region = "eastus"
        tenant_id      = "11111111-1111-1111-1111-111111111111"
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
      networking = {
        vnets = {
          mgmt = {
            location      = "eastus"
            address_space = "10.10.0.0/20"
          }
        }
        envs = {
          nonprod = {
            regions = {
              eastus  = { address_space = "10.20.0.0/20", pod_cidr_slot = 0 }
              westus2 = { address_space = "10.21.0.0/20", pod_cidr_slot = 1 }
            }
          }
          prod = {
            regions = {
              eastus = { address_space = "10.30.0.0/20" } # pod_cidr_slot intentionally omitted
            }
          }
        }
      }
    }
  }

  assert {
    condition     = length(keys(output.networking_derived.envs)) == 3
    error_message = "Flattened envs map must contain one entry per (env, region) pair."
  }

  assert {
    condition = alltrue([
      contains(keys(output.networking_derived.envs), "nonprod/eastus"),
      contains(keys(output.networking_derived.envs), "nonprod/westus2"),
      contains(keys(output.networking_derived.envs), "prod/eastus"),
    ])
    error_message = "Flattened envs map keys must be `<env>/<region>`."
  }

  assert {
    condition     = output.networking_derived.envs["nonprod/westus2"].vnet_name == "vnet-acme-nonprod-westus2"
    error_message = "Second region of an env must derive its own VNet name."
  }

  assert {
    condition     = output.networking_derived.envs["prod/eastus"].peering_env_to_mgmt_name == "peer-prod-eastus-to-mgmt"
    error_message = "Prod env-region peering names must not collide with nonprod."
  }

  # Per-region pod_cidr_slot passthrough and envelope derivation. nonprod/westus2
  # uses slot=1 → envelope 100.80.0.0/12; prod/eastus omits the field → null.
  assert {
    condition = alltrue([
      output.networking_derived.envs["nonprod/eastus"].pod_cidr_envelope == "100.64.0.0/12",
      output.networking_derived.envs["nonprod/westus2"].pod_cidr_envelope == "100.80.0.0/12",
      output.networking_derived.envs["prod/eastus"].pod_cidr_slot == null,
      output.networking_derived.envs["prod/eastus"].pod_cidr_envelope == null,
    ])
    error_message = "pod_cidr_envelope derivation must track pod_cidr_slot; an omitted slot must yield null on both fields."
  }
}

# ---- networking_derived: two-pool capacity ---------------------------------
#
# Two-pool layout: capacity = min(16, 2 * (2^(24-N) - 2)).
# /19 → min(16, 2 * 30) = 16   (still api-pool-bound; widening past /20
#                               does not raise capacity)
# /21 → min(16, 2 * 6)  = 12
# /22 → min(16, 2 * 2)  = 4

run "networking_derived_capacity_two_pool" {
  command = apply

  variables {
    fleet_doc = {
      fleet = {
        name           = "acme"
        primary_region = "eastus"
        tenant_id      = "11111111-1111-1111-1111-111111111111"
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
      networking = {
        vnets = {
          mgmt = { location = "eastus", address_space = "10.10.0.0/19" }
        }
        envs = {
          nonprod = {
            regions = {
              eastus = { address_space = "10.20.0.0/21" }
            }
          }
          prod = {
            regions = {
              eastus = { address_space = "10.30.0.0/22" }
            }
          }
        }
      }
    }
  }

  assert {
    condition     = output.networking_derived.mgmt.cluster_slot_capacity == 16
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

  # First /26 should still be the first /26 of the VNet regardless of size.
  assert {
    condition     = output.networking_derived.mgmt.snet_pe_shared_cidr == "10.10.0.0/26"
    error_message = "snet-pe-shared must be the first /26 regardless of VNet size."
  }
}
