terraform {
  required_version = "~> 1.14"

  required_providers {
    github = {
      source  = "integrations/github"
      version = "~> 6.12"
    }
    azapi = {
      source  = "Azure/azapi"
      version = "~> 2.9"
    }
  }
}
