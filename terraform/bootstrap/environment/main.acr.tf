# main.acr.tf
#
# Fleet-wide Azure Container Registry — created here on env=mgmt runs only
# (REFACTOR.md Step 1; PLAN §4 bootstrap/environment env=mgmt).
#
# Mgmt is a fleet-wide singleton under PLAN §1 hub-and-spoke; absorbing the
# fleet ACR into env=mgmt eliminates Stage 0 (REFACTOR.md). The ACR lives in
# `rg-fleet-shared` (created by `bootstrap/fleet`, NOT in `rg-fleet-mgmt-shared`)
# and its private endpoint lands in mgmt's `snet-pe-fleet` subnet, co-located
# with `acr.location` via same-region-else-first (PLAN §3.4).
#
# All resources here are gated `count = var.env == "mgmt" ? 1 : 0`. Non-mgmt
# env runs (nonprod, prod, ...) skip them entirely; for those envs,
# `local.fleet_acr_id` in main.identities.tf resolves to the synthesized ARM
# id of the same ACR as created here on a prior env=mgmt run.
#
# Repo-level vars `ACR_RESOURCE_ID`, `ACR_NAME`, `ACR_LOGIN_SERVER` are
# published at the bottom of this file (replacing the Stage 0 outputs of the
# same name). Per-cluster kubelet identities are granted `AcrPull` against
# this ACR by Stage 1 (condition-bounded via the env UAMI's `acr_uaa_bounded`
# role assignment in main.github.tf).

locals {
  # Fleet-shared RG id — `rg-fleet-shared` is created by `bootstrap/fleet`
  # in the ACR subscription. Reconstructed by name (parity with the Stage 0
  # `local.derived.fleet_shared_rg_id` it replaces).
  fleet_shared_rg_id = "/subscriptions/${local.derived.acr_subscription_id}/resourceGroups/${local.derived.acr_resource_group}"

  # `acr_sku` is not exposed via `module.identity.derived`; read directly
  # from the YAML doc with the same default as Stage 0 used.
  acr_sku = try(local.fleet_doc.acr.sku, "Premium")

  # Central BYO `privatelink.azurecr.io` zone id (PLAN §3.4); precondition
  # below asserts non-null + correct shape before the PE is created.
  pdz_azurecr = local.networking_central.pdz_azurecr

  # --- Cluster inventory scan -----------------------------------------------
  #
  # Mirrors Stage 0's scan (terraform/stages/0-fleet/main.tf). Used here only
  # for the singleton-mgmt precondition; redirect-URI derivation for the
  # Argo / Kargo AAD apps moves to Stage 1 mgmt (REFACTOR.md Step 4), not
  # here.
  cluster_files = sort(fileset("${path.module}/../../../clusters", "*/*/*/cluster.yaml"))

  clusters = [
    for f in local.cluster_files : {
      env    = split("/", f)[0]
      region = split("/", f)[1]
      name   = split("/", f)[2]
      role   = try(yamldecode(file("${path.module}/../../../clusters/${f}")).cluster.role, "workload")
    }
  ]

  mgmt_clusters = [for c in local.clusters : c if c.role == "management"]

  # Mgmt region co-located with the fleet ACR. Same-region-else-first;
  # mirrors the Stage 0 selector. Used to land the ACR PE in the correct
  # mgmt VNet's `snet-pe-fleet` subnet.
  acr_mgmt_region = (
    length(var.mgmt_pe_fleet_subnet_ids) == 0 ? "" :
    contains(keys(var.mgmt_pe_fleet_subnet_ids), local.derived.acr_location) ? (
      local.derived.acr_location
    ) : keys(var.mgmt_pe_fleet_subnet_ids)[0]
  )
}

# -----------------------------------------------------------------------------
# Singleton-mgmt enforcement.
#
# PLAN §1 hard-limits a fleet to exactly one cluster with `cluster.role:
# management`. The check fires as a precondition on a `terraform_data`
# resource so the failure surfaces during plan/refresh — before any apply
# work — per REFACTOR.md Step 1.
# -----------------------------------------------------------------------------

resource "terraform_data" "mgmt_singleton_check" {
  count = var.env == "mgmt" ? 1 : 0

  # Re-evaluate when the inventory changes; cosmetic — preconditions fire
  # regardless of input drift.
  input = length(local.mgmt_clusters)

  lifecycle {
    precondition {
      condition     = length(local.mgmt_clusters) == 1
      error_message = "PLAN §1 hub-and-spoke: a fleet must declare exactly one cluster with `cluster.role: management` (under clusters/<env>/<region>/<name>/cluster.yaml). Found ${length(local.mgmt_clusters)}: ${jsonencode([for c in local.mgmt_clusters : "${c.env}/${c.region}/${c.name}"])}."
    }
  }
}

# -----------------------------------------------------------------------------
# Fleet ACR (env=mgmt only). Body verbatim from the Stage 0 it replaces.
# -----------------------------------------------------------------------------

resource "azapi_resource" "fleet_acr" {
  count = var.env == "mgmt" ? 1 : 0

  # Preview API version is required: `softDeletePolicy`,
  # `azureADAuthenticationAsArmPolicy`, and `anonymousPullEnabled` are not
  # exposed in stable schemas as of azapi 2.9. Re-evaluate when the
  # 2024-xx-xx stable api-version that absorbs these graduates.
  type      = "Microsoft.ContainerRegistry/registries@2023-11-01-preview"
  name      = local.derived.acr_name
  parent_id = local.fleet_shared_rg_id
  location  = local.derived.acr_location

  body = {
    sku = { name = local.acr_sku }
    properties = {
      adminUserEnabled     = false
      anonymousPullEnabled = false
      # Private from day one — all pulls flow through the PE below, which
      # registers in the central privatelink.azurecr.io zone. Data-plane
      # reach from runners / AKS kubelets relies on the mgmt VNet
      # ↔ spoke peerings authored by bootstrap/fleet + bootstrap/environment
      # and the central PDZ's VNet links (owned by the adopter).
      publicNetworkAccess = "Disabled"
      zoneRedundancy      = "Enabled"
      # Policies
      policies = {
        quarantinePolicy                 = { status = "disabled" }
        trustPolicy                      = { type = "Notary", status = "disabled" }
        retentionPolicy                  = { days = 30, status = "enabled" }
        exportPolicy                     = { status = "enabled" }
        azureADAuthenticationAsArmPolicy = { status = "enabled" }
        softDeletePolicy                 = { retentionDays = 7, status = "enabled" }
      }
    }
  }

  response_export_values = ["id", "properties.loginServer"]
}

# -----------------------------------------------------------------------------
# Private endpoint for the fleet ACR. Lands in the `snet-pe-fleet` subnet of
# the mgmt VNet in `local.acr_mgmt_region` (same-region-else-first). The
# preconditions surface a mismatch / missing PDZ before the PE is created.
# -----------------------------------------------------------------------------

resource "azapi_resource" "fleet_acr_pe" {
  count = var.env == "mgmt" ? 1 : 0

  type      = "Microsoft.Network/privateEndpoints@2023-11-01"
  name      = "pe-${local.derived.acr_name}-registry"
  parent_id = local.fleet_shared_rg_id
  location  = local.derived.acr_location

  body = {
    properties = {
      subnet = {
        id = var.mgmt_pe_fleet_subnet_ids[local.acr_mgmt_region]
      }
      privateLinkServiceConnections = [
        {
          name = "plsc-${local.derived.acr_name}-registry"
          properties = {
            privateLinkServiceId = azapi_resource.fleet_acr[0].output.id
            groupIds             = ["registry"]
          }
        }
      ]
    }
  }

  lifecycle {
    precondition {
      condition     = contains(keys(var.mgmt_pe_fleet_subnet_ids), local.derived.acr_location)
      error_message = "clusters/_fleet.yaml: no networking.envs.mgmt.regions.<region> entry matches the fleet ACR location (`acr.location` = ${local.derived.acr_location}); the fleet ACR PE cannot land in a co-located mgmt VNet. Add a mgmt region in that location, or change `acr.location`."
    }
    precondition {
      condition     = local.pdz_azurecr != null && can(regex("^/subscriptions/[0-9a-fA-F-]{36}/resourceGroups/[^/]+/providers/Microsoft\\.Network/privateDnsZones/privatelink\\.azurecr\\.io$", local.pdz_azurecr))
      error_message = "clusters/_fleet.yaml: networking.private_dns_zones.azurecr must be a full ARM resource id ending in `/providers/Microsoft.Network/privateDnsZones/privatelink.azurecr.io`. See docs/adoption.md §5.1."
    }
  }

  response_export_values = ["id"]
}

resource "azapi_resource" "fleet_acr_pe_dns_zone_group" {
  count = var.env == "mgmt" ? 1 : 0

  type      = "Microsoft.Network/privateEndpoints/privateDnsZoneGroups@2023-11-01"
  name      = "default"
  parent_id = azapi_resource.fleet_acr_pe[0].id

  body = {
    properties = {
      privateDnsZoneConfigs = [
        {
          name = "privatelink-azurecr-io"
          properties = {
            privateDnsZoneId = local.pdz_azurecr
          }
        }
      ]
    }
  }
}

# -----------------------------------------------------------------------------
# Repo-level GitHub Actions variables for downstream consumers.
#
# Replaces the Stage 0 outputs of the same name. REPOSITORY-scoped (NOT env-
# scoped) per REFACTOR.md Step 1 — these flow into Stage 1 / Stage 2 of every
# cluster and into other env runs, so a per-env scope would be wrong. The
# fleet-meta GitHub App (provider configured in providers.tf) holds the
# `actions_variables: write` repo permission required to author these.
# -----------------------------------------------------------------------------

resource "github_actions_variable" "acr_resource_id" {
  count = var.env == "mgmt" ? 1 : 0

  repository    = local.fleet.github_repo
  variable_name = "ACR_RESOURCE_ID"
  value         = azapi_resource.fleet_acr[0].id
}

resource "github_actions_variable" "acr_name" {
  count = var.env == "mgmt" ? 1 : 0

  repository    = local.fleet.github_repo
  variable_name = "ACR_NAME"
  value         = local.derived.acr_name
}

resource "github_actions_variable" "acr_login_server" {
  count = var.env == "mgmt" ? 1 : 0

  repository    = local.fleet.github_repo
  variable_name = "ACR_LOGIN_SERVER"
  value         = azapi_resource.fleet_acr[0].output.properties.loginServer
}
