# stages/1-cluster/providers.tf
#
# Provider set: azapi + azurerm + random. Plans against the
# **cluster's own subscription** (read from the loader-emitted
# `cluster.subscription_id`, which falls back to
# `environments.<env>.subscription_id` per PLAN §3.3). Every AKS, KV,
# UAMI, subnet, and DNS resource authored here lives there.
#
# Repo-variable inputs (all consumed via `TF_VAR_*` piped from
# `tf-apply.yaml`, never via plan-time Azure data-source calls):
#   - `bootstrap/fleet` publishes `MGMT_VNET_RESOURCE_IDS` on the
#     `fleet-meta` GitHub Environment, plus `ARGO_AAD_APP_ID`,
#     `KARGO_AAD_APP_ID`, `KARGO_AAD_APPLICATION_OBJECT_ID` as
#     repo-level vars (the AAD apps are operator-owned in
#     `bootstrap/fleet`; see PLAN §4 Stage -1).
#   - `bootstrap/environment` env=mgmt publishes `ACR_*` as
#     repo-level vars.
#   - The mgmt cluster's own Stage 1 apply publishes
#     `MGMT_CLUSTER_KV_ID`, `MGMT_AKS_*`, and
#     `KARGO_MGMT_UAMI_*` as repo-level vars for spoke clusters'
#     Stage 1/2 to consume.
#   - `bootstrap/environment` publishes the per-env variables
#     (`FLEET_ENV_UAMI_PRINCIPAL_ID`, `MONITOR_WORKSPACE_ID`,
#     `DCE_ID`, `ACTION_GROUP_ID`) and the per-env-region
#     networking variables (`<ENV>_<REGION>_VNET_RESOURCE_ID`,
#     `<ENV>_<REGION>_NODE_ASG_RESOURCE_ID`,
#     `<ENV>_<REGION>_ROUTE_TABLE_RESOURCE_ID`).
# The mgmt VNet id is selected per-cluster via
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
