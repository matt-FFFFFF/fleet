# stages/1-cluster/providers.tf
#
# Provider set: azapi + azurerm + azuread + time + random. Plans against
# the **cluster's own subscription** (read from the loader-emitted
# `cluster.subscription_id`, which falls back to
# `environments.<env>.subscription_id` per PLAN §3.3). Every AKS, KV,
# UAMI, subnet, and DNS resource authored here lives there.
#
# `azuread` + `time` are present ONLY for the management cluster's
# Kargo OIDC-client-secret rotation (PLAN §4 Stage 1 lines 1772-1778):
# an `azuread_application_password` scoped to the Stage 0-owned Kargo
# AAD app, rotated every 60 days via a `time_rotating` resource, and
# written into the cluster KV as an azapi KV secret. On workload
# clusters these providers are configured but unused (the rotation
# resources are gated on `local.mgmt_cluster`); declaring them
# unconditionally keeps the provider surface uniform across legs.
#
# `bootstrap/fleet` publishes the fleet-scope repo + fleet-meta
# variables this stack needs: `MGMT_VNET_RESOURCE_IDS` (JSON-encoded
# `{region: vnet-resource-id}` map) on the `fleet-meta` GitHub
# Environment; `FLEET_KEYVAULT_ID`, `ACR_RESOURCE_ID`,
# `KARGO_MGMT_UAMI_PRINCIPAL_ID`, `KARGO_AAD_APPLICATION_OBJECT_ID` as
# fleet-scope repo variables. `bootstrap/environment` publishes the
# per-env variables (`FLEET_ENV_UAMI_PRINCIPAL_ID`,
# `MONITOR_WORKSPACE_ID`, `DCE_ID`, `ACTION_GROUP_ID`) and the
# per-env-region networking variables
# (`<ENV>_<REGION>_VNET_RESOURCE_ID`,
# `<ENV>_<REGION>_NODE_ASG_RESOURCE_ID`,
# `<ENV>_<REGION>_ROUTE_TABLE_RESOURCE_ID`). Stage 0 does **not**
# proxy any of these — adopters wire them directly from the
# `bootstrap/*` outputs into the `tf-apply.yaml` workflow (PLAN §10;
# not yet implemented — see STATUS §10), which pipes the values into
# `TF_VAR_*` so this stack never does a plan-time Azure data-source
# call. The mgmt VNet id is selected per-cluster via
# `fromJSON(vars.MGMT_VNET_RESOURCE_IDS)[derived.networking.peer_mgmt_region]`
# (same-region-else-first resolution done by config-loader/load.sh)
# and piped into `TF_VAR_mgmt_region_vnet_resource_id`.

terraform {
  required_version = "~> 1.14"

  required_providers {
    azapi = {
      source  = "Azure/azapi"
      version = "~> 2.9"
    }
    # azurerm carveout for the AVM AKS module (PLAN §2; see
    # modules/aks-cluster/terraform.tf for the rationale). Feature
    # coverage we actually plan to use: `diagnostic_settings` →
    # Log Analytics, `role_assignments` in the RBAC phase.
    azurerm = {
      source  = "hashicorp/azurerm"
      version = "~> 4.46"
    }
    # Mgmt-cluster-only (Kargo OIDC secret rotation). Declared
    # unconditionally so the provider set is uniform across legs;
    # workload clusters initialize the provider but author no
    # `azuread_*` resources.
    azuread = {
      source  = "hashicorp/azuread"
      version = "~> 3.0"
    }
    time = {
      source  = "hashicorp/time"
      version = "~> 0.12"
    }
    random = {
      source  = "hashicorp/random"
      version = "~> 3.8"
    }
  }

  backend "azurerm" {
    # Init-time values (see backend.tf for the full flag list):
    #   key = stage1/<env>/<region>/<name>.tfstate
  }
}

provider "azapi" {
  tenant_id       = local.fleet.tenant_id
  subscription_id = local.cluster.subscription_id
  use_oidc        = true
}

provider "azurerm" {
  tenant_id       = local.fleet.tenant_id
  subscription_id = local.cluster.subscription_id
  use_oidc        = true
  features {}
}

provider "azuread" {
  tenant_id = local.fleet.tenant_id
  use_oidc  = true
}
