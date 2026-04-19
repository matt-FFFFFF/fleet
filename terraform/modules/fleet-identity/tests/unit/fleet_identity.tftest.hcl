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

  # All networking.* default to null when _fleet.yaml has no networking block.
  assert {
    condition = alltrue([
      output.networking.tfstate_pe_subnet_id == null,
      output.networking.tfstate_pe_private_dns_zone_id == null,
      output.networking.runner_subnet_id == null,
      output.networking.runner_acr_pe_subnet_id == null,
      output.networking.runner_acr_dns_zone_id == null,
      output.networking.fleet_kv_pe_subnet_id == null,
      output.networking.fleet_kv_pe_dns_zone_id == null,
    ])
    error_message = "All networking.* identifiers must be null when fleet_doc.networking is absent."
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

# ---- networking passthrough: values are exposed verbatim when present ------

run "networking_passthrough_when_populated" {
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
        tfstate = {
          private_endpoint = {
            subnet_id           = "/subscriptions/s/resourceGroups/r/providers/Microsoft.Network/virtualNetworks/v/subnets/pe-state"
            private_dns_zone_id = "/subscriptions/s/resourceGroups/r/providers/Microsoft.Network/privateDnsZones/privatelink.blob.core.windows.net"
          }
        }
        runner = {
          subnet_id                              = "/subscriptions/s/.../subnets/runner-aca"
          container_registry_pe_subnet_id        = "/subscriptions/s/.../subnets/runner-acr-pe"
          container_registry_private_dns_zone_id = "/subscriptions/s/.../privateDnsZones/privatelink.azurecr.io"
        }
        fleet_kv = {
          private_endpoint = {
            subnet_id           = "/subscriptions/s/.../subnets/pe-kv"
            private_dns_zone_id = "/subscriptions/s/.../privateDnsZones/privatelink.vaultcore.azure.net"
          }
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
    condition     = endswith(output.networking.tfstate_pe_subnet_id, "/subnets/pe-state")
    error_message = "networking.tfstate.private_endpoint.subnet_id must pass through verbatim."
  }

  assert {
    condition     = output.networking.runner_subnet_id != null && output.networking.runner_acr_dns_zone_id != null
    error_message = "networking.runner.* must pass through when populated."
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
