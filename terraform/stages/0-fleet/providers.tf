terraform {
  required_version = "~> 1.9"

  required_providers {
    azapi = {
      source  = "Azure/azapi"
      version = "~> 2.9"
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
    # Init-time values (see backend.tf):
    #   resource_group_name  = <state RG from bootstrap/fleet>
    #   storage_account_name = <state SA from bootstrap/fleet>
    #   container_name       = tfstate-fleet
    #   key                  = stage0/fleet.tfstate
    #   use_oidc             = true
    #   use_azuread_auth     = true
  }
}

# ACR, fleet KV and the Kargo UAMI all live in the fleet-shared subscription
# (fleet.acr.subscription_id, which by convention == fleet.keyvault.subscription_id).
provider "azapi" {
  tenant_id       = local.fleet.tenant_id
  subscription_id = local.derived.acr_subscription_id
  use_oidc        = true
}

provider "azuread" {
  tenant_id = local.fleet.tenant_id
  use_oidc  = true
}
