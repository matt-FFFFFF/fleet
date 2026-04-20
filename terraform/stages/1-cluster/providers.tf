# stages/1-cluster/providers.tf
#
# Same provider set as Stage 0 (azapi + azuread), with one difference:
# this stack plans against the **cluster's own subscription** (read
# from the loader-emitted `cluster.subscription_id`, which falls back
# to `environments.<env>.subscription_id` per PLAN §3.3). Every AKS,
# KV, UAMI, subnet, and DNS resource authored here lives there.
#
# Stage 0 publishes the fleet-scope repo variables this stack needs
# (`MGMT_VNET_RESOURCE_ID`, `FLEET_KEYVAULT_ID`, `KARGO_MGMT_UAMI_PRINCIPAL_ID`);
# `bootstrap/environment` publishes the per-env-region variables
# (`<ENV>_<REGION>_VNET_RESOURCE_ID`, `<ENV>_<REGION>_NODE_ASG_RESOURCE_ID`).
# The `tf-apply.yaml` workflow (PLAN §10; not yet implemented — see
# STATUS §10) pipes those into `TF_VAR_*` so this stack never does a
# plan-time Azure data-source call.

terraform {
  required_version = "~> 1.11"

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
      version = "~> 3.5"
    }
    azuread = {
      source  = "hashicorp/azuread"
      version = "~> 3.8"
    }
    time = {
      source  = "hashicorp/time"
      version = "~> 0.13"
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
