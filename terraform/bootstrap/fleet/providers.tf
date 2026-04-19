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
    # NOTE: azurerm is a narrow carveout — it is used ONLY transitively by
    # the vendored `modules/cicd-runners/` module (see PLAN §1 and
    # `terraform/modules/cicd-runners/VENDORING.md`). bootstrap/fleet itself
    # does not declare any `azurerm_*` resources or data sources; everything
    # this stage authors is `azapi_*`. The provider block below exists only
    # because Terraform requires the parent to configure every provider that
    # any child module references.
    azurerm = {
      source  = "hashicorp/azurerm"
      version = "~> 4.20"
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
  subscription_id = local.fleet_doc.acr.subscription_id
  # Operator runs `az login` (interactive) before `terraform apply`.
  use_cli = true
}

provider "azuread" {
  tenant_id = local.fleet.tenant_id
  use_cli   = true
}

provider "azurerm" {
  tenant_id       = local.fleet.tenant_id
  subscription_id = local.fleet_doc.acr.subscription_id
  use_cli         = true
  features {}
}

provider "github" {
  owner = local.fleet.github_org
  # Auth: operator exports GITHUB_TOKEN (a classic PAT with org:admin +
  # repo:admin scope) before running. This token is used only for the
  # initial repo + GH App install; all downstream CI uses OIDC.
}
