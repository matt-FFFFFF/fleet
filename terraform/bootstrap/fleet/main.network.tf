# main.network.tf
#
# Repo-owned mgmt-tier VNet (PLAN §3.4). Authored via the
# `Azure/avm-ptn-alz-sub-vending/azure` module (N=1, no mesh, hub peering
# enabled). The sub-vending module is used purely for its network-layer
# creation — subscription creation is DISABLED (we run against the
# already-bootstrapped shared subscription) — but we still go through it
# because it is the same abstraction `bootstrap/environment` uses for
# env-tier VNets, which keeps the two stages symmetric and makes
# upstream network-design changes land in one place.
#
# Carves two reserved /26 subnets:
#   - snet-pe-shared  → tfstate SA, fleet KV, fleet ACR private endpoints
#   - snet-runners    → ACA-delegated self-hosted GitHub runner pool
#
# Subnet CIDRs come from `networking_derived.mgmt.snet_{pe_shared,runners}_cidr`
# (first and second /26 of the VNet address_space; see docs/naming.md).
#
# Peering to the adopter-owned hub is delegated to the sub-vending
# module (`hub_peering_enabled = true`). Mgmt↔env peerings are
# authored separately by `bootstrap/environment` via the peering AVM
# submodule with `create_reverse_peering = true` so both halves land
# in the env state in a single apply; this stage only ensures the
# `fleet-meta` UAMI holds `Network Contributor` on the mgmt VNet so
# that reverse half can be written (see role assignment below).

# --- Preflight on the Phase-B networking inputs -----------------------------
#
# Pattern mirrors main.state.tf / main.runner.tf: reject null / empty /
# legacy `<...>` sentinel / non-ARM-id shapes with a single yaml-anchored
# error. Without these, the sub-vending module / azapi provider fail
# much later with cryptic errors.

resource "terraform_data" "network_preconditions" {
  input = {
    hub_resource_id = local.networking_central.hub_resource_id
    pdz_blob        = local.networking_central.pdz_blob
    pdz_vaultcore   = local.networking_central.pdz_vaultcore
    pdz_azurecr     = local.networking_central.pdz_azurecr
    mgmt_address_space = try(
      local.networking_derived.mgmt.address_space,
      null,
    )
  }

  lifecycle {
    precondition {
      condition     = local.networking_central.hub_resource_id != null && local.networking_central.hub_resource_id != "" && !startswith(local.networking_central.hub_resource_id, "<") && startswith(local.networking_central.hub_resource_id, "/subscriptions/")
      error_message = "clusters/_fleet.yaml: networking.hub.resource_id is unset, still a `<...>` placeholder, or not a /subscriptions/... resource id. Replace it with the full /subscriptions/.../virtualNetworks/<name> id of the adopter-owned hub VNet. See docs/adoption.md §5.1 + docs/networking.md."
    }
    precondition {
      condition     = local.networking_central.pdz_blob != null && local.networking_central.pdz_blob != "" && !startswith(local.networking_central.pdz_blob, "<") && endswith(local.networking_central.pdz_blob, "privatelink.blob.core.windows.net")
      error_message = "clusters/_fleet.yaml: networking.private_dns_zones.blob is unset, still a `<...>` placeholder, or does not end in `privatelink.blob.core.windows.net`. Replace it with the resource id of the central BYO blob PDZ. See docs/adoption.md §5.1."
    }
    precondition {
      condition     = local.networking_central.pdz_vaultcore != null && local.networking_central.pdz_vaultcore != "" && !startswith(local.networking_central.pdz_vaultcore, "<") && endswith(local.networking_central.pdz_vaultcore, "privatelink.vaultcore.azure.net")
      error_message = "clusters/_fleet.yaml: networking.private_dns_zones.vaultcore is unset, still a `<...>` placeholder, or does not end in `privatelink.vaultcore.azure.net`. See docs/adoption.md §5.1."
    }
    precondition {
      condition     = local.networking_central.pdz_azurecr != null && local.networking_central.pdz_azurecr != "" && !startswith(local.networking_central.pdz_azurecr, "<") && endswith(local.networking_central.pdz_azurecr, "privatelink.azurecr.io")
      error_message = "clusters/_fleet.yaml: networking.private_dns_zones.azurecr is unset, still a `<...>` placeholder, or does not end in `privatelink.azurecr.io`. See docs/adoption.md §5.1."
    }
    precondition {
      condition     = try(local.networking_derived.mgmt.address_space, null) != null
      error_message = "clusters/_fleet.yaml: networking.vnets.mgmt.address_space is required for bootstrap/fleet. See docs/adoption.md §5.1 + PLAN §3.4."
    }
  }
}

# --- Mgmt VNet via sub-vending (N=1, no mesh, hub peering) ------------------

locals {
  mgmt_vnet_name = local.networking_derived.mgmt.vnet_name # vnet-<fleet>-mgmt
  mgmt_rg_name   = local.networking_derived.mgmt.rg_name   # rg-net-mgmt
  mgmt_rg_key    = "net-mgmt"                              # internal map key for sub-vending

  mgmt_vnet_key = "mgmt" # internal map key for sub-vending

  snet_pe_shared_name = "snet-pe-shared"
  snet_runners_name   = "snet-runners"

  nsg_pe_shared_key = "pe-shared"
  nsg_runners_key   = "runners"

  # Node-resource-id string of the mgmt VNet is
  # "<rg-id>/providers/Microsoft.Network/virtualNetworks/<name>". The
  # sub-vending module returns this via `virtual_network_resource_ids[<key>]`.
  # Reference it through that output once it exists; see `local.mgmt_vnet_id`.
}

module "mgmt_network" {
  source  = "Azure/avm-ptn-alz-sub-vending/azure"
  version = "~> 0.2"

  depends_on = [terraform_data.network_preconditions]

  enable_telemetry = false

  # Run against the already-bootstrapped shared subscription; do NOT
  # create or mutate the subscription.
  subscription_alias_enabled                        = false
  subscription_id                                   = local.derived.acr_subscription_id
  subscription_update_existing                      = false
  subscription_management_group_association_enabled = false

  location = local.networking_derived.mgmt.location

  # --- Resource group ------------------------------------------------------
  resource_group_creation_enabled = true
  resource_groups = {
    (local.mgmt_rg_key) = {
      name     = local.mgmt_rg_name
      location = local.networking_derived.mgmt.location
      tags = {
        fleet     = local.fleet.name
        component = "networking"
        stage     = "bootstrap-fleet"
      }
    }
  }

  # --- NSGs ----------------------------------------------------------------
  network_security_group_enabled = true
  network_security_groups = {
    (local.nsg_pe_shared_key) = {
      name               = "nsg-pe-shared"
      location           = local.networking_derived.mgmt.location
      resource_group_key = local.mgmt_rg_key
      # Default-deny only — PE subnets need no explicit ingress; the PLS
      # handles the traffic. Azure NSG has implicit Allow-Outbound and
      # Deny-Inbound at priority 65500 which is what we want.
      security_rules = {}
    }
    (local.nsg_runners_key) = {
      name               = "nsg-runners"
      location           = local.networking_derived.mgmt.location
      resource_group_key = local.mgmt_rg_key
      # Outbound-only: ACA jobs reach GitHub + Azure control plane via
      # hub firewall (UDR on the subnet). No ingress required.
      security_rules = {}
    }
  }

  # --- Mgmt VNet + subnets -------------------------------------------------
  virtual_network_enabled = true
  virtual_networks = {
    (local.mgmt_vnet_key) = {
      name               = local.mgmt_vnet_name
      resource_group_key = local.mgmt_rg_key
      location           = local.networking_derived.mgmt.location
      address_space      = [local.networking_derived.mgmt.address_space]

      subnets = {
        pe-shared = {
          name             = local.snet_pe_shared_name
          address_prefixes = [local.networking_derived.mgmt.snet_pe_shared_cidr]
          network_security_group = {
            key_reference = local.nsg_pe_shared_key
          }
        }
        runners = {
          name             = local.snet_runners_name
          address_prefixes = [local.networking_derived.mgmt.snet_runners_cidr]
          network_security_group = {
            key_reference = local.nsg_runners_key
          }
          # ACA requires delegation to Microsoft.App/environments on the
          # subnet; the vendored runner module expects a pre-delegated
          # subnet.
          delegations = [
            {
              name = "Microsoft.App.environments"
              service_delegation = {
                name    = "Microsoft.App/environments"
                actions = ["Microsoft.Network/virtualNetworks/subnets/action"]
              }
            }
          ]
        }
      }

      # --- Hub peering (tohub + fromhub) ------------------------------------
      hub_peering_enabled     = true
      hub_network_resource_id = local.networking_central.hub_resource_id
      hub_peering_direction   = "both"
      # Classic hub-and-spoke defaults; hub is likely running Azure
      # Firewall so we allow the mgmt VNet to use remote gateways and
      # the hub to forward traffic (standard spoke pattern).
      hub_peering_options_tohub = {
        allow_forwarded_traffic      = true
        allow_gateway_transit        = false
        allow_virtual_network_access = true
        use_remote_gateways          = false
      }
      hub_peering_options_fromhub = {
        allow_forwarded_traffic      = true
        allow_gateway_transit        = true
        allow_virtual_network_access = true
        use_remote_gateways          = false
      }

      # Intra-mesh peering is N/A at N=1; leave disabled.
      mesh_peering_enabled = false
    }
  }
}

# --- Derived subnet resource ids -------------------------------------------
#
# The sub-vending module does not expose subnet resource ids directly
# (only `virtual_network_resource_ids[key]`). Subnet ids follow the
# deterministic ARM path `<vnet-id>/subnets/<name>`, so we build them
# from the VNet output. This keeps downstream PE / ACA wiring anchored
# to a module output (ensuring the correct depends_on chain) while
# avoiding a provider data lookup.

locals {
  mgmt_vnet_id = module.mgmt_network.virtual_network_resource_ids[local.mgmt_vnet_key]

  snet_pe_shared_id = "${local.mgmt_vnet_id}/subnets/${local.snet_pe_shared_name}"
  snet_runners_id   = "${local.mgmt_vnet_id}/subnets/${local.snet_runners_name}"
}

# --- RBAC: fleet-meta UAMI → Network Contributor on the mgmt VNet ----------
#
# Env-bootstrap authors the reverse half of every mgmt↔env peering via
# the peering AVM submodule (create_reverse_peering = true). That PUT
# lands on the mgmt VNet in this stage's subscription, so the executor
# identity (`uami-fleet-meta`) needs Network Contributor on the mgmt
# VNet resource id. Scope is the VNet, not the RG, so the grant is
# minimal and survives renames of sibling mgmt resources.
#
# Built-in role GUID: Network Contributor
#   4d97b98b-1d4f-4787-a291-c67834d212e7

locals {
  role_network_contributor_guid = "4d97b98b-1d4f-4787-a291-c67834d212e7"
}

resource "azapi_resource" "ra_meta_mgmt_vnet_netctrb" {
  type      = "Microsoft.Authorization/roleAssignments@2022-04-01"
  name      = uuidv5("url", "fleet-meta-mgmt-vnet-netctrb-${local.mgmt_vnet_id}")
  parent_id = local.mgmt_vnet_id

  body = {
    properties = {
      roleDefinitionId = "/subscriptions/${local.derived.acr_subscription_id}/providers/Microsoft.Authorization/roleDefinitions/${local.role_network_contributor_guid}"
      principalId      = module.fleet_repo.environments["meta"].identity.principal_id
      principalType    = "ServicePrincipal"
    }
  }
}
