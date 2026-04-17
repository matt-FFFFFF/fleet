terraform {
  required_version = "~> 1.9"

  required_providers {
    azapi = {
      source  = "Azure/azapi"
      version = "~> 2.9"
    }
    github = {
      source  = "integrations/github"
      version = "~> 6.11"
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
