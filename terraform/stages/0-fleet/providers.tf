terraform {
  required_version = ">= 1.9.0"

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
    # Init-time:
    #   resource_group_name  = rg-fleet-tfstate
    #   storage_account_name = <fleet.state.storage_account>
    #   container_name       = tfstate-fleet
    #   key                  = stage0/fleet.tfstate
    #   use_oidc             = true
    #   use_azuread_auth     = true
  }
}

provider "azapi" {
  tenant_id       = var.fleet.tenant_id
  subscription_id = var.fleet.acr.subscription_id # sub-fleet-shared
  use_oidc        = true
}

provider "azuread" {
  tenant_id = var.fleet.tenant_id
  use_oidc  = true
}
