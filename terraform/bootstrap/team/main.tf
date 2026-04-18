# bootstrap/team
#
# Actions-run via .github/workflows/team-bootstrap.yaml under the fleet-meta
# GitHub environment. Triggered on PR merge that adds a new
# platform-gitops/config/teams/<team>.yaml. Creates the team's GitHub repo
# from the team-repo-template + branch-protection ruleset + Kargo GH App
# install.
#
# Phase 1 stub: Kargo GH App install is not wired yet (App ID is not known
# until init-gh-apps.sh lands per PLAN §16.4). Repo + ruleset + initial
# CODEOWNERS ARE provisioned by the current module call below.

terraform {
  required_version = "~> 1.11"

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

provider "github" { owner = var.github_org }

module "team_repo" {
  source = "../../modules/github-repo"

  name        = "${var.team}-gitops"
  description = "GitOps repo for team ${var.team}"
  visibility  = "private"

  delete_branch_on_merge = true
  vulnerability_alerts   = true

  template = {
    owner      = var.github_org
    repository = var.team_template_repo
  }

  # Seed CODEOWNERS so PRs require the team's review from day one.
  files = {
    ".github/CODEOWNERS" = "* @${var.github_org}/${var.team}\n"
  }

  # Branch-protection via repository ruleset — matches bootstrap/fleet's
  # main-branch ruleset shape.
  rulesets = {
    main = {
      name        = "main-branch-protection"
      enforcement = "active"
      target      = "branch"
      conditions = {
        ref_name = {
          include = ["~DEFAULT_BRANCH"]
          exclude = []
        }
      }
      rules = {
        non_fast_forward    = true
        required_signatures = true
        pull_request = {
          required_approving_review_count = 1
          require_code_owner_review       = true
        }
      }
      bypass_actors = []
    }
  }
}

# TODO(phase6): Kargo GH App installation on this repo via
# `github_app_installation_repositories` once the App ID is known.
