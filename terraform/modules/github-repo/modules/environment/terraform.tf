terraform {
  required_version = "~> 1.11"

  required_providers {
    github = {
      source  = "integrations/github"
      version = "~> 6.11"
    }
    azapi = {
      source  = "Azure/azapi"
      version = "~> 2.9"
    }
  }
}
