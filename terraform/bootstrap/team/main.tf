# bootstrap/team
#
# Actions-run via .github/workflows/team-bootstrap.yaml under the fleet-meta
# GitHub environment. Triggered on PR merge that adds a new
# platform-gitops/config/teams/<team>.yaml. Creates the team's GitHub repo
# from the team-repo-template + branch protection + Kargo GH App install.
#
# Phase 1 stub: the full wiring depends on the org's GH-repo module (see
# bootstrap/fleet/main.github.tf comment). For now the workflow simply
# documents the next operator step.

terraform {
  required_version = "~> 1.9"
  required_providers {
    github = {
      source  = "integrations/github"
      version = "~> 6.11"
    }
  }

  backend "azurerm" {
    # resource_group_name  = rg-fleet-tfstate
    # storage_account_name = <fleet.state.storage_account>
    # container_name       = tfstate-fleet
    # key                  = bootstrap/team/<team>.tfstate
    # use_oidc             = true
    # use_azuread_auth     = true
  }
}

variable "github_org" { type = string }
variable "team" {
  description = "Team name = filename basename of platform-gitops/config/teams/<team>.yaml. Derived by the team-bootstrap workflow."
  type        = string

  validation {
    condition     = can(regex("^[a-z0-9]([a-z0-9-]{0,61}[a-z0-9])?$", var.team))
    error_message = "team must be a DNS label (see PLAN §7)."
  }
}

variable "team_template_repo" {
  type    = string
  default = "team-repo-template"
}

variable "fleet_repo" {
  type    = string
  default = "fleet"
}

provider "github" { owner = var.github_org }

resource "github_repository" "team" {
  name        = "${var.team}-gitops"
  description = "GitOps repo for team ${var.team}"
  visibility  = "private"

  template {
    owner      = var.github_org
    repository = var.team_template_repo
  }

  delete_branch_on_merge = true
  vulnerability_alerts   = true

  lifecycle {
    prevent_destroy = true
    ignore_changes  = [topics, template]
  }
}

resource "github_branch_protection" "team_main" {
  repository_id = github_repository.team.node_id
  pattern       = "main"

  required_pull_request_reviews {
    required_approving_review_count = 1
    require_code_owner_reviews      = true
  }

  require_signed_commits = true
  enforce_admins         = false
}

# CODEOWNERS seeding: create initial CODEOWNERS file pointing at the team.
resource "github_repository_file" "codeowners" {
  repository          = github_repository.team.name
  branch              = "main"
  file                = ".github/CODEOWNERS"
  content             = "* @${var.github_org}/${var.team}\n"
  commit_message      = "Seed CODEOWNERS for team ${var.team}"
  overwrite_on_create = true
}

# TODO(phase6): Kargo GH App installation on this repo via
# `github_app_installation_repositories` once the App ID is known.
