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
    github = {
      source  = "integrations/github"
      version = "~> 6.11"
    }
    random = {
      source  = "hashicorp/random"
      version = "~> 3.8"
    }
    time = {
      source  = "hashicorp/time"
      version = "~> 0.13"
    }
  }
}

# bootstrap/fleet runs once, LOCALLY, by a tenant-admin + subscription-owner.
# Local state is intentional — this stage creates the remote state backend
# that every other stage uses. The `.terraform/` directory and local state
# files are gitignored; only the .tf files and lockfile ship.

provider "azapi" {
  tenant_id       = local.fleet.tenant_id
  subscription_id = local._fleet_doc.acr.subscription_id
  # Operator runs `az login` (interactive) before `terraform apply`.
  use_cli = true
}

provider "azuread" {
  tenant_id = local.fleet.tenant_id
  use_cli   = true
}

provider "github" {
  owner = local.fleet.github_org
  # Auth: operator exports GITHUB_TOKEN (a classic PAT with org:admin +
  # repo:admin scope) before running. This token is used only for the
  # initial repo + GH App install; all downstream CI uses OIDC.
}
