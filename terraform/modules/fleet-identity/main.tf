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

  # Private-networking identifiers. All try-guarded so older / partial
  # `_fleet.yaml` docs (pre-networking-schema) remain parseable — an
  # adopter fills these in before the relevant apply. The rendered yaml
  # ships these fields as `null` with a TODO comment (see
  # init/templates/_fleet.yaml.tftpl) so downstream `!= null && != ""`
  # preconditions catch "adopter forgot to fill this in" with a single
  # check.
  #
  # NOTE (PLAN §3.4). Legacy BYO subnet ids
  # (`networking.{tfstate,fleet_kv,runner}.*`) are being replaced by
  # repo-owned VNets derived from `networking.vnets.mgmt` and
  # `networking.envs.<env>.regions.<region>`. The legacy fields remain
  # exposed here for pre-Phase-B consumers (`bootstrap/fleet`'s current
  # `main.state.tf` / `main.runner.tf` / `main.fleet-kv.tf`) and will
  # disappear in Phase C/D when those callsites rewire to
  # `networking_derived` below.
  networking = {
    tfstate_pe_subnet_id           = try(var.fleet_doc.networking.tfstate.private_endpoint.subnet_id, null)
    tfstate_pe_private_dns_zone_id = try(var.fleet_doc.networking.tfstate.private_endpoint.private_dns_zone_id, null)
    runner_subnet_id               = try(var.fleet_doc.networking.runner.subnet_id, null)
    runner_acr_pe_subnet_id        = try(var.fleet_doc.networking.runner.container_registry_pe_subnet_id, null)
    runner_acr_dns_zone_id         = try(var.fleet_doc.networking.runner.container_registry_private_dns_zone_id, null)
    fleet_kv_pe_subnet_id          = try(var.fleet_doc.networking.fleet_kv.private_endpoint.subnet_id, null)
    fleet_kv_pe_dns_zone_id        = try(var.fleet_doc.networking.fleet_kv.private_endpoint.private_dns_zone_id, null)
  }

  # -- Repo-owned VNet topology (PLAN §3.4) -----------------------------------
  #
  # All fleet-scope + env-scope networking derivations. Cluster-scope
  # derivations (`snet-aks-api-<cluster>` / `snet-aks-nodes-<cluster>` CIDRs
  # as two /25s of the slot's /24) live in `terraform/config-loader/load.sh`
  # and in Stage 1 HCL — they need `cluster.{env,region,name,subnet_slot}`
  # which this module has no input for. Parity is the contract (see
  # docs/naming.md).
  #
  # Every field is `try()`-guarded against the networking block being
  # absent or partial, so pre-Phase-B `_fleet.yaml` renders (which carry
  # no `networking.vnets` / `networking.envs.<env>.regions`) yield
  # `null`s without raising. Downstream callsites assert non-null before
  # using.
  #
  # CIDR math. For a VNet `/N` with address_space A:
  #   reserved /26s: first = snet-pe-<shared|env> ; mgmt also reserves
  #     the second /26 for snet-runners.
  #   cluster /24 for slot K (0-indexed) = cidrsubnet(A, 24-N, K+1)
  #     (the `+1` skips the first /24 whose low /26s are reserved).
  #   capacity = 2^(24-N) - 1 (one /24 consumed by the reserved /26s).
  # At /20 (the default floor) that's 15 cluster slots, per PLAN §3.4.
  _mgmt_vnet          = try(var.fleet_doc.networking.vnets.mgmt, null)
  _mgmt_address_space = try(local._mgmt_vnet.address_space, null)

  _env_regions_raw = try(var.fleet_doc.networking.envs, {})

  # Flatten `envs.<env>.regions.<region>` into a map keyed "<env>/<region>".
  # Map values stay `try()`-guarded so a partial region block doesn't crash
  # the derivation.
  _env_regions = merge([
    for env_name, env_block in local._env_regions_raw : {
      for region_name, region_block in try(env_block.regions, {}) :
      "${env_name}/${region_name}" => {
        env           = env_name
        region        = region_name
        address_space = try(region_block.address_space, null)
        location      = try(region_block.location, region_name)
      }
    }
  ]...)

  networking_derived = {
    mgmt = local._mgmt_vnet == null ? null : {
      vnet_name     = "vnet-${local.fleet.name}-mgmt"
      rg_name       = "rg-net-mgmt"
      address_space = local._mgmt_address_space
      location      = try(local._mgmt_vnet.location, local.fleet.primary_region)
      # First /26 of the VNet, regardless of VNet size.
      snet_pe_shared_cidr = local._mgmt_address_space == null ? null : cidrsubnet(local._mgmt_address_space, 26 - tonumber(split("/", local._mgmt_address_space)[1]), 0)
      # Second /26 of the VNet — ACA-delegated runner pool.
      snet_runners_cidr = local._mgmt_address_space == null ? null : cidrsubnet(local._mgmt_address_space, 26 - tonumber(split("/", local._mgmt_address_space)[1]), 1)
      # Cluster-slot capacity (for completeness; mgmt VNet currently
      # hosts a single cluster per region but the math is symmetric).
      cluster_slot_capacity = local._mgmt_address_space == null ? null : pow(2, 24 - tonumber(split("/", local._mgmt_address_space)[1])) - 1
    }

    envs = {
      for key, r in local._env_regions : key => {
        env           = r.env
        region        = r.region
        location      = r.location
        address_space = r.address_space
        vnet_name     = "vnet-${local.fleet.name}-${r.env}-${r.region}"
        rg_name       = "rg-net-${r.env}"
        # First /26 of the env VNet — shared PE subnet for the env
        # (Grafana PE, etc.).
        snet_pe_env_cidr = r.address_space == null ? null : cidrsubnet(r.address_space, 26 - tonumber(split("/", r.address_space)[1]), 0)
        # Number of usable cluster slots in this env-region.
        cluster_slot_capacity = r.address_space == null ? null : pow(2, 24 - tonumber(split("/", r.address_space)[1])) - 1
        # Peering names (both halves — mgmt↔env peering lives in the
        # env state via the peering AVM module with
        # create_reverse_peering = true).
        peering_env_to_mgmt_name = "peer-${r.env}-${r.region}-to-mgmt"
        peering_mgmt_to_env_name = "peer-mgmt-to-${r.env}-${r.region}"
        # One ASG per env-region, shared by every cluster in the VNet.
        node_asg_name = "asg-nodes-${r.env}-${r.region}"
        nsg_pe_name   = "nsg-pe-env-${r.env}-${r.region}"
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
