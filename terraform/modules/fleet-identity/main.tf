# fleet-identity/main.tf
#
# Derivation rules. Single source alongside:
#   - docs/naming.md               (canonical spec)
#   - terraform/config-loader/load.sh (shell impl consumed by Stage 1/2)
# Change all three together; CI does not (yet) diff them.

locals {
  fleet = var.fleet_doc.fleet

  # Convenience: the `envs.<env>` map from _fleet.yaml. Used below to
  # source the mgmt location (mgmt's scalar `location` is the canonical
  # source for fleet-wide resources that aren't bound to a cluster
  # env-region — fleet RGs, fleet-meta UAMI, tenant-scope role
  # assignments, fleet ACR). `fleet.primary_region` no longer exists
  # per PLAN §3.1.
  envs          = try(var.fleet_doc.envs, {})
  mgmt_env      = try(local.envs.mgmt, null)
  mgmt_location = try(local.mgmt_env.location, null)

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
    fleet_kv_location       = try(var.fleet_doc.keyvault.location, local.mgmt_location)
  }

  # Central adopter-owned networking inputs — the four central
  # `privatelink.*` private DNS zones used for PE A-record registration.
  # All BYO; referenced by resource id only. `try()`-guarded so partial
  # `_fleet.yaml` docs stay parseable; downstream callsites assert
  # non-null with `precondition` blocks.
  #
  # Hub VNet references are per-(env,region) under
  # `networking.envs.<env>.regions.<region>.hub_network_resource_id`
  # (PLAN §3.4); see `env_regions` below for the passthrough.
  networking_central = {
    pdz_blob      = try(var.fleet_doc.networking.private_dns_zones.blob, null)
    pdz_vaultcore = try(var.fleet_doc.networking.private_dns_zones.vaultcore, null)
    pdz_azurecr   = try(var.fleet_doc.networking.private_dns_zones.azurecr, null)
    pdz_grafana   = try(var.fleet_doc.networking.private_dns_zones.grafana, null)
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
  # absent or partial, so partial `_fleet.yaml` renders yield `null`s
  # without raising. Downstream callsites assert non-null before using.
  #
  # CIDR math (PLAN §3.4 L678-706). For a VNet `/N` with
  # address_space A the layout is:
  #
  #   Non-mgmt env-region VNet:
  #     reserved /24 (index 0)   → snet-pe-env   (first /26 of reserved)
  #     api /24      (index 1)   → 16 × /28       (per cluster subnet_slot)
  #     nodes pool   (index 2+)  → 2 × /25 per /24 (per cluster subnet_slot)
  #
  #   Mgmt env-region VNet (everything above PLUS):
  #     fleet zone = upper /(N+1) of A (`cidrsubnet(A, 1, 1)`)
  #       snet-runners  = first /23 of fleet zone     (ACA-delegated)
  #       snet-pe-fleet = /26 at index 8 of fleet zone (CI-plane PEs)
  #
  # Cluster slot capacity (non-mgmt): min(16, 2 * (2^(24-N) - 2)).
  # Mgmt is capped softly at ~2-4 at /20 (the fleet zone eats the upper
  # /21, leaving only the lower /21 for cluster pools). Same formula
  # applied; operators self-police the mgmt cluster count.

  env_regions_raw = try(var.fleet_doc.networking.envs, {})

  # Flatten `envs.<env>.regions.<region>` into a map keyed
  # "<env>/<region>". `address_space` is expected to be a YAML list of
  # CIDR strings (PLAN §3.1); we pick the first entry for CIDR math.
  # `location` defaults to the region name. Passes through the
  # per-env-region hub reference, egress next-hop, and
  # `create_reverse_peering` toggle so Stage -1 can consume them.
  env_regions = merge([
    for env_name, env_block in local.env_regions_raw : {
      for region_name, region_block in try(env_block.regions, {}) :
      "${env_name}/${region_name}" => {
        env                     = env_name
        region                  = region_name
        address_space           = try(tolist(region_block.address_space), null)
        cidr                    = try(tolist(region_block.address_space)[0], null)
        location                = try(region_block.location, region_name)
        hub_network_resource_id = try(region_block.hub_network_resource_id, null)
        egress_next_hop_ip      = try(region_block.egress_next_hop_ip, null)
        create_reverse_peering  = try(region_block.create_reverse_peering, true)

        # Hub-and-spoke knobs (F6). All optional, defaults preserve the
        # pre-F6 "island VNet" behaviour so existing adopters see no
        # change.
        #
        # `use_remote_gateways` — plumbed to
        # `hub_peering_options_tohub.use_remote_gateways` on the spoke→
        # hub peering. `true` is required when the hub owns a VPN /
        # ExpressRoute gateway the spoke needs to reach; default `false`
        # preserves backward compat for topologies where the hub has no
        # gateway (unconditional `true` would break them).
        use_remote_gateways = try(region_block.hub_peering.use_remote_gateways, false)

        # `dns_servers` — plumbed to `virtual_networks.<k>.dns_servers`.
        # Empty list = Azure-provided DNS (168.63.129.16), the module
        # default. Populate with central Private DNS Resolver inbound
        # endpoint IPs when split-horizon / on-prem DNS forwarding is
        # required.
        # Use coalesce(try(...), typed_zero) so an explicit YAML
        # `dns_servers: null` (which `tolist(null)` would pass through)
        # is normalised to the typed empty list alongside the
        # attribute-absent case.
        dns_servers = coalesce(try(tolist(region_block.dns_servers), null), tolist([]))

        # `subnet_route_table_ids` — per-subnet external RT override.
        # Keys reference fleet- and env-plane subnets this repo owns:
        # `pe-fleet`, `runners` (mgmt only), `pe-env` (all envs). Values
        # are full ARM route-table resource ids. An explicit override
        # wins over any RT the repo might otherwise create from
        # `egress_next_hop_ip`. Precedence:
        #   1. `subnet_route_table_ids.<subnet>` (adopter-owned hub RT)
        #   2. repo-created RT derived from `egress_next_hop_ip`
        #   3. no RT attached (pre-F6 default)
        # Validation of keys + id format lives at the bootstrap/fleet +
        # bootstrap/environment call sites; this layer is a passthrough.
        # Same null-coalescing pattern as `dns_servers`: an explicit
        # YAML `subnet_route_table_ids: null` must not propagate to
        # downstream `for`-preconditions, which would error on null.
        subnet_route_table_ids = coalesce(try(tomap(region_block.subnet_route_table_ids), null), tomap({}))
      }
    }
  ]...)

  # Flat map of mgmt env-regions — used by non-mgmt env-region peering
  # derivation to resolve the peer mgmt VNet. In practice at most one
  # mgmt region is expected per fleet-config, but the map is kept open.
  mgmt_regions = {
    for k, r in local.env_regions : r.region => r
    if r.env == "mgmt"
  }

  # Uniform per-(env, region) derivation. Every entry carries the full
  # set of cluster-workload fields (valid on every env including mgmt).
  # Mgmt entries additionally carry fleet-plane fields
  # (`snet_pe_fleet_cidr`, `snet_runners_cidr`). Non-mgmt entries set
  # those two fields to null.
  networking_derived = {
    envs = {
      for key, r in local.env_regions : key => {
        env           = r.env
        region        = r.region
        location      = r.location
        address_space = r.address_space
        cidr          = r.cidr

        # Repo-owned resource names (uniform across envs incl. mgmt).
        vnet_name = "vnet-${local.fleet.name}-${r.env}-${r.region}"
        rg_name   = "rg-net-${r.env}-${r.region}"

        # Cluster-workload subnet zone: first /24 of A → first /26 is
        # snet-pe-env. Guarded by `can(cidrnetmask(...))` so a malformed
        # or absent CIDR yields null rather than crashing plan-time.
        snet_pe_env_cidr = r.cidr == null ? null : (can(cidrnetmask(r.cidr)) ? cidrsubnet(cidrsubnet(r.cidr, 24 - tonumber(split("/", r.cidr)[1]), 0), 2, 0) : null)

        # Cluster slot capacity (two-pool layout):
        # min(16, 2 * (2^(24-N) - 2)). Api-pool-bound at /20+.
        cluster_slot_capacity = r.cidr == null ? null : (can(cidrnetmask(r.cidr)) ? min(16, 2 * (pow(2, 24 - tonumber(split("/", r.cidr)[1])) - 2)) : null)

        # One ASG per env-region, shared by every cluster in the VNet.
        node_asg_name = "asg-nodes-${r.env}-${r.region}"

        # Env-PE NSG. Uniform naming across envs incl. mgmt.
        nsg_pe_env_name = "nsg-pe-env-${r.env}-${r.region}"

        # Route table associated with BOTH api and nodes subnets
        # (PLAN §3.4 UDR for AKS egress, "api-server VNet integration
        # egresses through the same next-hop as nodes").
        route_table_name = "rt-aks-${r.env}-${r.region}"

        # Peerings — per PLAN §3.3 new table, names include mgmt
        # region ("-to-mgmt-<mgmt-region>"). Authored from env state
        # (spoke side) for every non-mgmt env-region, with
        # reverse-half gated on `create_reverse_peering`. For mgmt
        # env-regions the fields are null (mgmt↔env peering is the
        # non-mgmt env's responsibility; mgmt↔hub is owned by
        # `bootstrap/fleet`).
        peering_spoke_to_mgmt_name = r.env == "mgmt" ? null : (
          length(keys(local.mgmt_regions)) == 0 ? null :
          "peer-${r.env}-${r.region}-to-mgmt-${contains(keys(local.mgmt_regions), r.region) ? r.region : keys(local.mgmt_regions)[0]}"
        )
        peering_mgmt_to_spoke_name = r.env == "mgmt" ? null : (
          length(keys(local.mgmt_regions)) == 0 ? null :
          "peer-mgmt-${contains(keys(local.mgmt_regions), r.region) ? r.region : keys(local.mgmt_regions)[0]}-to-${r.env}-${r.region}"
        )

        # Per-env-region peering toggle (passthrough).
        create_reverse_peering = r.create_reverse_peering

        # Adopter-owned hub VNet this env-region peers to (PLAN §3.4).
        # When null, no hub peering is created for this env-region
        # (escape hatch; adopter handles routing externally). Mgmt↔hub
        # peering is owned by `bootstrap/fleet`; non-mgmt env↔hub
        # peering is owned by `bootstrap/environment`.
        hub_network_resource_id = r.hub_network_resource_id

        # Adopter-supplied next-hop IP for the `0.0.0.0/0` UDR on
        # cluster-workload subnets. `bootstrap/environment` authors
        # `rt-aks-<env>-<region>` on every env-region unconditionally;
        # the route entry is only created when this is non-null.
        # Stage 1 preconditions on non-null at cluster-apply time for
        # regions that host clusters. Null is the template-repo default.
        egress_next_hop_ip = r.egress_next_hop_ip

        # Mgmt-only fleet-plane zone (PLAN §3.4 L691-706). Upper /(N+1)
        # of A; within it, snet-runners = first /23, snet-pe-fleet =
        # /26 at index 8 of the fleet zone. All null for non-mgmt.
        snet_runners_cidr = r.env != "mgmt" || r.cidr == null ? null : (
          can(cidrnetmask(r.cidr)) ? cidrsubnet(cidrsubnet(r.cidr, 1, 1), 22 - tonumber(split("/", r.cidr)[1]), 0) : null
        )
        snet_pe_fleet_cidr = r.env != "mgmt" || r.cidr == null ? null : (
          can(cidrnetmask(r.cidr)) ? cidrsubnet(cidrsubnet(r.cidr, 1, 1), 25 - tonumber(split("/", r.cidr)[1]), 8) : null
        )

        # Fleet-plane NSG names (mgmt-only; null elsewhere).
        nsg_pe_fleet_name = r.env == "mgmt" ? "nsg-pe-fleet-${r.region}" : null
        nsg_runners_name  = r.env == "mgmt" ? "nsg-runners-${r.region}" : null

        # Fleet-plane route table (F6). When the adopter has set
        # `egress_next_hop_ip` on a mgmt region, `bootstrap/fleet`
        # creates `rt-fleet-<region>` with a single
        # `0.0.0.0/0 → VirtualAppliance → <ip>` route and attaches it
        # to `snet-pe-fleet` and `snet-runners` (unless
        # `subnet_route_table_ids.<subnet>` supplies an adopter-owned
        # external id, which wins). Null on non-mgmt env-regions
        # (cluster-plane RT is named `rt-aks-<env>-<region>` and is
        # already owned by `bootstrap/environment`).
        rt_fleet_name = r.env == "mgmt" ? "rt-fleet-${r.region}" : null

        # Hub-and-spoke passthroughs (F6). `bootstrap/fleet` and
        # `bootstrap/environment` consume these as-is.
        use_remote_gateways    = r.use_remote_gateways
        dns_servers            = r.dns_servers
        subnet_route_table_ids = r.subnet_route_table_ids
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
