terraform {
  required_version = "~> 1.11"

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
    #   subscription_id      = <_fleet.yaml state.subscription_id>
    #   container_name       = tfstate-fleet
    #   key                  = stage0/fleet.tfstate
    #   use_oidc             = true
    #   use_azuread_auth     = true
    #
    # NOTE: subscription_id above is the state subscription (where the
    # tfstate storage account lives), not acr.subscription_id. With OIDC
    # auth, omitting it lets the provider fall back to ARM_SUBSCRIPTION_ID
    # or the current az CLI context — both error-prone. Always pass it.
  }
}

# ACR, fleet KV, and the Kargo UAMI all live in the fleet-shared subscription
# identified by _fleet.yaml acr.subscription_id; the fleet KV does not carry
# its own subscription_id field and implicitly inherits this one.
provider "azapi" {
  tenant_id       = local.fleet.tenant_id
  subscription_id = local.derived.acr_subscription_id
  use_oidc        = true
}

provider "azuread" {
  tenant_id = local.fleet.tenant_id
  use_oidc  = true
}
