# fleet-identity/main.tf
#
# Derivation rules. Single source alongside:
#   - docs/naming.md               (canonical spec)
#   - terraform/config-loader/load.sh (shell impl consumed by Stage 1/2)
# Change all three together; CI does not (yet) diff them.

locals {
  fleet = var.fleet_doc.fleet

  # Derived names. `coalesce(override, formula)` pattern lets an explicit
  # override win; when the override is empty/absent the formula result is
  # used. For KV and SA names, `substr(..., 0, 24)` truncates only the
  # formula-derived fallback; non-empty overrides pass through unchanged
  # and must already satisfy Azure's length constraints. Formulas mirror
  # docs/naming.md §"Derived names".
  derived = {
    # ----- tfstate storage ------------------------------------------------
    state_storage_account = coalesce(
      try(var.fleet_doc.state.storage_account_name_override, ""),
      substr("st${local.fleet.name}tfstate", 0, 24),
    )
    state_resource_group = var.fleet_doc.state.resource_group
    state_container      = var.fleet_doc.state.containers.fleet
    state_subscription   = var.fleet_doc.state.subscription_id

    # ----- fleet ACR ------------------------------------------------------
    acr_name = coalesce(
      try(var.fleet_doc.acr.name_override, ""),
      "acr${local.fleet.name}shared",
    )
    acr_resource_group  = var.fleet_doc.acr.resource_group
    acr_subscription_id = var.fleet_doc.acr.subscription_id
    acr_location        = var.fleet_doc.acr.location

    # ----- fleet Key Vault ------------------------------------------------
    fleet_kv_name = coalesce(
      try(var.fleet_doc.keyvault.name_override, ""),
      substr("kv-${local.fleet.name}-fleet", 0, 24),
    )
    fleet_kv_resource_group = try(var.fleet_doc.keyvault.resource_group, var.fleet_doc.acr.resource_group)
    fleet_kv_location       = try(var.fleet_doc.keyvault.location, local.fleet.primary_region)
  }

  # Central adopter-owned networking inputs — the hub VNet the repo peers
  # to and the four central `privatelink.*` private DNS zones used for
  # PE A-record registration. All BYO; referenced by resource id only.
  # `try()`-guarded so older / partial `_fleet.yaml` docs stay parseable;
  # downstream callsites assert non-null with `precondition` blocks.
  #
  # PLAN §3.4: this is the Phase-B schema. Pre-Phase-B BYO per-service
  # subnet ids (`networking.{tfstate,fleet_kv,runner}.*`) are gone —
  # those subnets are now owned by this repo via `networking_derived`.
  networking_central = {
    hub_resource_id = try(var.fleet_doc.networking.hub.resource_id, null)
    pdz_blob        = try(var.fleet_doc.networking.private_dns_zones.blob, null)
    pdz_vaultcore   = try(var.fleet_doc.networking.private_dns_zones.vaultcore, null)
    pdz_azurecr     = try(var.fleet_doc.networking.private_dns_zones.azurecr, null)
    pdz_grafana     = try(var.fleet_doc.networking.private_dns_zones.grafana, null)
  }

  # -- Repo-owned VNet topology (PLAN §3.4) -----------------------------------
  #
  # All fleet-scope + env-scope networking derivations. Cluster-scope
  # per-subnet CIDRs (i-th /28 in the API pool + i-th /25 in the nodes
  # pool, keyed on `cluster.subnet_slot`) live in
  # `terraform/config-loader/load.sh` and in Stage 1 HCL — this module
  # has no input for `cluster.{env,region,name,subnet_slot}`. Parity is
  # the contract (see docs/naming.md).
  #
  # Every field is `try()`-guarded against the networking block being
  # absent or partial, so pre-Phase-B `_fleet.yaml` renders (which carry
  # no `networking.vnets` / `networking.envs.<env>.regions`) yield
  # `null`s without raising. Downstream callsites assert non-null before
  # using.
  #
  # CIDR math (two-pool layout). For a VNet `/N` with address_space A:
  #   reserved zone = first /24 of A  (snet-pe-<shared|env>; mgmt also
  #                                    hosts snet-runners in the 2nd /26)
  #   api pool      = 2nd /24 of A    → 16 × /28
  #   nodes pool    = 3rd /24 onward  → 2 × /25 per /24
  #   cluster_slot_capacity = min(16, 2 * (2^(24-N) - 2))
  # At /20 (the default) that's 16 slots (api-pool-bound). Widening the
  # VNet does not raise capacity beyond 16 — the api pool is a fixed
  # /24 with room for 16 /28s.
  mgmt_vnet          = try(var.fleet_doc.networking.vnets.mgmt, null)
  mgmt_address_space = try(local.mgmt_vnet.address_space, null)

  env_regions_raw = try(var.fleet_doc.networking.envs, {})

  # Flatten `envs.<env>.regions.<region>` into a map keyed "<env>/<region>".
  # Map values stay `try()`-guarded so a partial region block doesn't crash
  # the derivation.
  env_regions = merge([
    for env_name, env_block in local.env_regions_raw : {
      for region_name, region_block in try(env_block.regions, {}) :
      "${env_name}/${region_name}" => {
        env           = env_name
        region        = region_name
        address_space = try(region_block.address_space, null)
        location      = try(region_block.location, region_name)
        pod_cidr_slot = try(region_block.pod_cidr_slot, null)
      }
    }
  ]...)

  networking_derived = {
    mgmt = local.mgmt_vnet == null ? null : {
      vnet_name     = "vnet-${local.fleet.name}-mgmt"
      rg_name       = "rg-net-mgmt"
      address_space = local.mgmt_address_space
      location      = try(local.mgmt_vnet.location, local.fleet.primary_region)
      # All CIDR math below is guarded by `can(cidrnetmask(...))` so a
      # malformed address_space (missing `/N`, non-CIDR string) yields
      # nulls rather than crashing plan-time. `init/`'s validation block
      # already rejects bad CIDRs at the schema boundary, but this
      # module is also consumed by bootstrap stages post-adoption where
      # the YAML could drift; nulls flow to downstream preconditions
      # which emit typed errors.
      # First /26 of the VNet, regardless of VNet size.
      snet_pe_shared_cidr = can(cidrnetmask(local.mgmt_address_space)) ? cidrsubnet(local.mgmt_address_space, 26 - tonumber(split("/", local.mgmt_address_space)[1]), 0) : null
      # Second /26 of the VNet — ACA-delegated runner pool.
      snet_runners_cidr = can(cidrnetmask(local.mgmt_address_space)) ? cidrsubnet(local.mgmt_address_space, 26 - tonumber(split("/", local.mgmt_address_space)[1]), 1) : null
      # Cluster-slot capacity (for completeness; mgmt VNet currently
      # hosts a single cluster per region but the math is symmetric).
      # Two-pool layout: min(16, 2 * (2^(24-N) - 2)). Api-pool-bound
      # at /20 and wider.
      cluster_slot_capacity = can(cidrnetmask(local.mgmt_address_space)) ? min(16, 2 * (pow(2, 24 - tonumber(split("/", local.mgmt_address_space)[1])) - 2)) : null
    }

    envs = {
      for key, r in local.env_regions : key => {
        env           = r.env
        region        = r.region
        location      = r.location
        address_space = r.address_space
        vnet_name     = "vnet-${local.fleet.name}-${r.env}-${r.region}"
        rg_name       = "rg-net-${r.env}"
        # First /26 of the env VNet — shared PE subnet for the env
        # (Grafana PE, etc.). Guarded as above.
        snet_pe_env_cidr = can(cidrnetmask(r.address_space)) ? cidrsubnet(r.address_space, 26 - tonumber(split("/", r.address_space)[1]), 0) : null
        # Number of usable cluster slots in this env-region (two-pool
        # layout): min(16, 2 * (2^(24-N) - 2)). Api-pool-bound at /20
        # and wider.
        cluster_slot_capacity = can(cidrnetmask(r.address_space)) ? min(16, 2 * (pow(2, 24 - tonumber(split("/", r.address_space)[1])) - 2)) : null
        # Peering names (both halves — mgmt↔env peering lives in the
        # env state via the peering AVM module with
        # create_reverse_peering = true).
        peering_env_to_mgmt_name = "peer-${r.env}-${r.region}-to-mgmt"
        peering_mgmt_to_env_name = "peer-mgmt-to-${r.env}-${r.region}"
        # One ASG per env-region, shared by every cluster in the VNet.
        node_asg_name = "asg-nodes-${r.env}-${r.region}"
        nsg_pe_name   = "nsg-pe-env-${r.env}-${r.region}"
        # CGNAT pod-CIDR slot passthrough (PLAN §3.4). The region
        # reserves a /12 at 100.[64 + pod_cidr_slot*16].0.0/12 of
        # 100.64.0.0/10; per-cluster /16s are derived downstream
        # (config-loader/load.sh) as
        #   100.[64 + pod_cidr_slot*16 + cluster.subnet_slot].0.0/16
        # Null when the region block omits pod_cidr_slot (pre-Phase-B
        # renders); downstream preconditions check non-null.
        pod_cidr_slot = r.pod_cidr_slot
        # Reserved /12 envelope for the region's pod space (for docs
        # / diagnostics; not currently consumed directly by any
        # callsite — clusters author /16s scoped to it).
        pod_cidr_envelope = r.pod_cidr_slot == null ? null : "100.${64 + r.pod_cidr_slot * 16}.0.0/12"
      }
    }
  }

  # fleet-runners GitHub App (KEDA polling). See docs/adoption.md §4.
  github_app_fleet_runners = {
    app_id                = try(var.fleet_doc.github_app.fleet_runners.app_id, "")
    installation_id       = try(var.fleet_doc.github_app.fleet_runners.installation_id, "")
    private_key_kv_secret = try(var.fleet_doc.github_app.fleet_runners.private_key_kv_secret, "fleet-runners-app-pem")
  }
}
