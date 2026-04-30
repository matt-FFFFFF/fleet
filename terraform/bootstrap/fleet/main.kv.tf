# main.kv.tf
#
# Runner-pool Key Vault — exactly ONE per fleet, strictly private (PE-only).
#
# Stage ownership: bootstrap/fleet (Stage -1) owns KV creation so that
# the Stage -1 runner pool's Container App Job can reference the GH App
# PEM secret (`fleet-runners-app-pem`) at module-apply time. The two
# GH App PEMs (`fleet-runners-app-pem`, `fleet-meta-app-pem`) are
# seeded into this vault by the data-plane PUTs at the bottom of this
# file; the operator running `bootstrap/fleet apply` holds
# `Key Vault Secrets Officer` (self-grant below) so first-apply
# succeeds without a manual portal step.
#
# Networking pattern mirrors the per-pool ACR:
#   - publicNetworkAccess = Disabled
#   - networkAcls.defaultAction = Deny, bypass = None
#   - Private endpoint on networking.runners_kv.private_endpoint.subnet_id
#   - A-record registered in the operator-supplied central
#     privatelink.vaultcore.azure.net zone (BYO, typically in the hub
#     connectivity subscription; symmetric with
#     privatelink.blob.core.windows.net for tfstate and
#     privatelink.azurecr.io for the runner ACR).
#
# Consequence for operators: the `init-gh-apps.sh` helper that seeds the
# GH App PEM(s) into this KV must run from a host with private-network
# reach to the vault (e.g. a jump host in the hub, a VPN, or the fleet
# runners themselves after they are online). See docs/adoption.md §5.2.
#
# Soft-delete + purge protection are mandatory. RBAC authorization mode
# (no access policies) is mandatory.

resource "azapi_resource" "runners_kv" {
  type      = "Microsoft.KeyVault/vaults@2023-07-01"
  name      = local.derived.runners_kv_name
  parent_id = azapi_resource.rg_fleet_runners.id
  location  = local.derived.runners_kv_location

  body = {
    properties = {
      tenantId                  = local.fleet.tenant_id
      sku                       = { family = "A", name = "standard" }
      enableRbacAuthorization   = true
      enablePurgeProtection     = true
      enableSoftDelete          = true
      softDeleteRetentionInDays = 90
      publicNetworkAccess       = "Disabled"
      networkAcls = {
        # bypass = None: Azure trusted services (Monitor, Backup, Policy)
        # must also traverse the PE; there is no "azure services" escape
        # hatch. Symmetric with the tfstate SA.
        bypass              = "None"
        defaultAction       = "Deny"
        ipRules             = []
        virtualNetworkRules = []
      }
    }
  }

  response_export_values = ["id", "properties.vaultUri"]
}

# State-migration shim: the resource was previously named
# `azapi_resource.fleet_kv`; `moved {}` keeps existing state addressed
# correctly across the rename so the vault is not destroyed + recreated.
moved {
  from = azapi_resource.fleet_kv
  to   = azapi_resource.runners_kv
}

# --- Private endpoint --------------------------------------------------------
#
# Lands in the `snet-pe-fleet` subnet of the mgmt VNet co-located with
# the runners KV (by `runners_kv_location`, defaulting to mgmt's scalar
# location). PLAN §3.4. A-record registers in the adopter-owned central
# `privatelink.vaultcore.azure.net` zone from
# `networking.private_dns_zones.vaultcore`.

locals {
  # Pick the mgmt region matching the KV's location; fall back to the
  # first mgmt region. The precondition below surfaces a mismatch early.
  runners_kv_mgmt_region = contains(keys(local.mgmt_vnet_ids), local.derived.runners_kv_location) ? (
    local.derived.runners_kv_location
  ) : keys(local.mgmt_vnet_ids)[0]
}

resource "azapi_resource" "runners_kv_pe" {
  type      = "Microsoft.Network/privateEndpoints@2023-11-01"
  name      = "pe-${local.derived.runners_kv_name}-vault"
  parent_id = azapi_resource.rg_fleet_runners.id
  location  = local.derived.runners_kv_location

  body = {
    properties = {
      subnet = {
        id = local.mgmt_snet_pe_fleet_ids[local.runners_kv_mgmt_region]
      }
      privateLinkServiceConnections = [
        {
          name = "plsc-${local.derived.runners_kv_name}-vault"
          properties = {
            privateLinkServiceId = azapi_resource.runners_kv.output.id
            groupIds             = ["vault"]
          }
        }
      ]
    }
  }

  lifecycle {
    precondition {
      condition     = contains(keys(local.mgmt_vnet_ids), local.derived.runners_kv_location)
      error_message = "clusters/_fleet.yaml: no networking.envs.mgmt.regions.<region> entry matches the runners KV location (`runners_keyvault.location` resolves to ${local.derived.runners_kv_location}); the runners KV PE cannot land in a co-located mgmt VNet."
    }
  }

  response_export_values = ["id"]
}

moved {
  from = azapi_resource.fleet_kv_pe
  to   = azapi_resource.runners_kv_pe
}

resource "azapi_resource" "runners_kv_pe_dns_zone_group" {
  type      = "Microsoft.Network/privateEndpoints/privateDnsZoneGroups@2023-11-01"
  name      = "default"
  parent_id = azapi_resource.runners_kv_pe.id

  body = {
    properties = {
      privateDnsZoneConfigs = [
        {
          name = "privatelink-vaultcore-azure-net"
          properties = {
            privateDnsZoneId = local.networking_central.pdz_vaultcore
          }
        }
      ]
    }
  }
}

moved {
  from = azapi_resource.fleet_kv_pe_dns_zone_group
  to   = azapi_resource.runners_kv_pe_dns_zone_group
}

# --- RBAC: runner UAMI -> Key Vault Secrets User -----------------------------
#
# uami-fleet-runners must read `fleet-runners-app-pem` at runner-start time
# (ACA resolves the KV reference via the UAMI attached to the Container App
# Job). Built-in role guid:
#   Key Vault Secrets User  4633458b-17de-4321-8a42-03b4c0a0ebb2
#
# Issued at KV scope from this stage — the KV now exists in the same state
# graph as the UAMI, so the PUT succeeds in a single apply.

locals {
  role_kv_secrets_user_guid = "4633458b-17de-408a-b874-0445c86b69e6"
}

resource "azapi_resource" "ra_runner_kv_secrets_user" {
  type      = "Microsoft.Authorization/roleAssignments@2022-04-01"
  name      = uuidv5("url", "fleet-runners-kv-secrets-user-${azapi_resource.runners_kv.output.id}")
  parent_id = azapi_resource.runners_kv.output.id

  body = {
    properties = {
      roleDefinitionId = "/subscriptions/${local.derived.acr_subscription_id}/providers/Microsoft.Authorization/roleDefinitions/${local.role_kv_secrets_user_guid}"
      principalId      = azapi_resource.runner_uami.output.properties.principalId
      principalType    = "ServicePrincipal"
    }
  }
}

# --- RBAC: uami-fleet-meta -> Key Vault Secrets User -------------------------
#
# `env-bootstrap.yaml` and `team-bootstrap.yaml` run under the
# `fleet-meta` GH environment as `uami-fleet-meta`, then call
# `az keyvault secret show` to fetch the `fleet-meta-app-pem` secret
# and mint a GitHub App installation token (via
# `actions/create-github-app-token`) for the Terraform `github`
# provider. The UAMI therefore needs Key Vault Secrets User on the
# runners KV.
#
# Vault-wide scope (rather than per-secret) so future fleet-wide
# secrets seeded into this KV are reachable without additional role
# assignments.

resource "azapi_resource" "ra_meta_kv_secrets_user" {
  type      = "Microsoft.Authorization/roleAssignments@2022-04-01"
  name      = uuidv5("url", "fleet-meta-kv-secrets-user-${azapi_resource.runners_kv.output.id}")
  parent_id = azapi_resource.runners_kv.output.id

  body = {
    properties = {
      roleDefinitionId = "/subscriptions/${local.derived.acr_subscription_id}/providers/Microsoft.Authorization/roleDefinitions/${local.role_kv_secrets_user_guid}"
      principalId      = module.fleet_repo.environments["meta"].identity.principal_id
      principalType    = "ServicePrincipal"
    }
  }
}

# --- RBAC: operator -> Key Vault Secrets Officer (data-plane seeding) -------
#
# The operator running `bootstrap/fleet apply` (interactive `az login`,
# tenant admin + subscription owner) seeds two GH App PEMs into this
# vault via `azapi_data_plane_resource` PUTs below
# (`fleet_runners_pem_secret`, `fleet_meta_pem_secret`). Those PUTs hit
# the KV data-plane as the signed-in user and require an RBAC role on
# the vault — the runner UAMI grant above is read-only and scoped to a
# different principal.
#
# Without this role assignment, the first apply hard-fails on the data-
# plane PUT with `403 Forbidden / AccessDenied: Caller is not
# authorized to perform action on resource`, which strands the vault
# (created, PE wired, runner UAMI granted) but unable to hold the PEMs
# the runner needs to start. See historical F17 finding.
#
# Self-grant — same pattern as the operator -> mgmt cluster KV grant in
# `main.aad.tf` for the second-pass RP-secret writes. The role is
# scoped to this vault only; granting `Secrets Officer` to the same
# operator who already holds Owner on the subscription is not a
# privilege escalation, it just makes the stage self-sufficient on
# first apply.

data "azuread_client_config" "operator" {}

resource "azapi_resource" "ra_operator_runners_kv_secrets_officer" {
  type      = "Microsoft.Authorization/roleAssignments@2022-04-01"
  parent_id = azapi_resource.runners_kv.output.id
  # Deterministic GUID v5 over (scope, principalId, role) so re-runs
  # don't produce duplicate assignments. Same shape as
  # `operator_mgmt_kv_secrets_officer` in main.aad.tf.
  name = uuidv5("oid", "${azapi_resource.runners_kv.output.id}|${data.azuread_client_config.operator.object_id}|Key Vault Secrets Officer")

  body = {
    properties = {
      principalId   = data.azuread_client_config.operator.object_id
      principalType = "User"
      # Key Vault Secrets Officer (built-in)
      roleDefinitionId = "/providers/Microsoft.Authorization/roleDefinitions/b86a8fe4-44ce-4948-aee5-eccb2c155cd7"
    }
  }

  retry = {
    error_message_regex = ["AuthorizationFailed", "PrincipalNotFound"]
  }
}

output "runners_kv_id" {
  description = "Resource id of the runner-pool Key Vault."
  value       = azapi_resource.runners_kv.output.id
}

output "runners_kv_vault_uri" {
  description = "Data-plane URI of the runner-pool Key Vault (https://<name>.vault.azure.net/)."
  value       = azapi_resource.runners_kv.output.properties.vaultUri
}

# --- Seed fleet-runners GitHub App PEM --------------------------------------
#
# The runner Container App Job (main.runner.tf) references
# `<kv>/secrets/fleet-runners-app-pem` as a KV reference. ACA validates
# the reference at PUT time by attempting to fetch the secret via the
# attached UAMI, so the secret must exist before the job is created.
#
# Seeded via the KV data-plane API (7.4) so the PEM travels over the PE
# and never touches ARM / state. `sensitive_body` is a write-only schema
# attribute: the value is sent on create/update but never stored in
# Terraform state. `sensitive_body_version` is the only change-detection
# signal; bump `var.fleet_runners_app_pem_version` on rotation.
#
# Requires the executor (operator workstation or a runner) to have
# private-network reach to `<vault>.vault.azure.net`. With the KV
# PE + DNS zone group in place, a VPN / jump host / Bastion session
# into the mgmt VNet is sufficient.

resource "azapi_data_plane_resource" "fleet_runners_pem_secret" {
  type = "Microsoft.KeyVault/vaults/secrets@7.4"
  # azapi_data_plane_resource expects parent_id as the bare hostname
  # (`{vault}.vault.azure.net`), not the full vaultUri. The KV property
  # returns `https://{vault}.vault.azure.net/`; strip the scheme + trailing
  # slash so the provider builds a well-formed data-plane URL. See the
  # azapi provider's KV examples (Microsoft.KeyVault/vaults/secrets@7.4).
  parent_id = trimsuffix(trimprefix(azapi_resource.runners_kv.output.properties.vaultUri, "https://"), "/")
  name      = local.github_app_fleet_runners.private_key_kv_secret

  body = {
    contentType = "application/x-pem-file"
  }

  sensitive_body = {
    value = var.fleet_runners_app_pem
  }

  sensitive_body_version = {
    value = var.fleet_runners_app_pem_version
  }

  depends_on = [
    azapi_resource.runners_kv_pe_dns_zone_group,
    azapi_resource.ra_operator_runners_kv_secrets_officer,
  ]
}

# --- Seed fleet-meta GitHub App PEM -----------------------------------------
#
# Fetched at workflow runtime by `env-bootstrap.yaml` and
# `team-bootstrap.yaml` (which authenticate to KV as `uami-fleet-meta`
# via the `fleet-meta` GH environment OIDC FIC), then fed to
# `actions/create-github-app-token` to mint a short-lived installation
# token used as `GITHUB_TOKEN` by the Terraform `github` provider in
# `bootstrap/environment` and `bootstrap/team`.
#
# Same write-only `sensitive_body` pattern as the runners PEM above —
# the value never enters Terraform state. Bump
# `fleet_meta_app_pem_version` to force a re-PUT on rotation.

resource "azapi_data_plane_resource" "fleet_meta_pem_secret" {
  type      = "Microsoft.KeyVault/vaults/secrets@7.4"
  parent_id = trimsuffix(trimprefix(azapi_resource.runners_kv.output.properties.vaultUri, "https://"), "/")
  name      = local.github_app_fleet_meta.private_key_kv_secret

  body = {
    contentType = "application/x-pem-file"
  }

  sensitive_body = {
    value = var.fleet_meta_app_pem
  }

  sensitive_body_version = {
    value = var.fleet_meta_app_pem_version
  }

  depends_on = [
    azapi_resource.runners_kv_pe_dns_zone_group,
    azapi_resource.ra_operator_runners_kv_secrets_officer,
  ]
}
