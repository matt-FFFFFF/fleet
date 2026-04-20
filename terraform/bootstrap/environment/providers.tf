terraform {
  required_version = "~> 1.11"

  required_providers {
    azapi = {
      source  = "Azure/azapi"
      version = "~> 2.9"
    }
    github = {
      source  = "integrations/github"
      version = "~> 6.11"
    }
    # Required by Azure/avm-ptn-alz-sub-vending/azure (~> 0.2). The
    # provider emits anonymous module-telemetry; we silence it via the
    # module's `enable_telemetry = false` flag, but the provider must
    # still be declared at every callsite.
    modtm = {
      source  = "azure/modtm"
      version = "~> 0.3"
    }
    # Sub-vending also depends on `random ~> 3.5`; the existing
    # azapi/github stack does not pull `random`, so declare it here
    # explicitly.
    random = {
      source  = "hashicorp/random"
      version = "~> 3.8"
    }
  }

  backend "azurerm" {
    # Passed via -backend-config by the env-bootstrap workflow:
    #   resource_group_name  = <from bootstrap/fleet output>
    #   storage_account_name = <from bootstrap/fleet output>
    #   container_name       = tfstate-fleet
    #   key                  = bootstrap/environment/<env>.tfstate
    #   use_oidc             = true
    #   use_azuread_auth     = true
  }
}

provider "azapi" {
  tenant_id       = local.fleet.tenant_id
  subscription_id = local.environment.subscription_id
  use_oidc        = true # authenticating as uami-fleet-meta via GitHub OIDC
}

provider "github" {
  owner = local.fleet.github_org
  # GITHUB_TOKEN env var in CI — sourced from the fleet-meta GitHub App
  # installation token (via actions/create-github-app-token).
}

# Telemetry provider required by the sub-vending module. Empty block —
# `enable_telemetry = false` on the module call disables emission.
provider "modtm" {}
