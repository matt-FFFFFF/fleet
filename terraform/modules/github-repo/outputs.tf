output "repository" {
  description = "The full repository resource (null when create_repository is false)."
  value       = var.create_repository ? github_repository.this[0] : null
}

output "full_name" {
  description = "The full name of the repository (owner/name)."
  value       = var.create_repository ? github_repository.this[0].full_name : null
}

output "html_url" {
  description = "The URL to the repository on GitHub."
  value       = var.create_repository ? github_repository.this[0].html_url : null
}

output "ssh_clone_url" {
  description = "SSH clone URL of the repository."
  value       = var.create_repository ? github_repository.this[0].ssh_clone_url : null
}

output "http_clone_url" {
  description = "HTTP clone URL of the repository."
  value       = var.create_repository ? github_repository.this[0].http_clone_url : null
}

output "default_branch" {
  description = "The default branch of the repository."
  value       = var.default_branch
}

output "files" {
  description = "Map of managed file paths to their commit SHAs."
  value       = { for k, v in github_repository_file.this : k => v.commit_sha }
}

output "actions_oidc_subject_claim_values" {
  description = "Map of configured OIDC subject claim keys to their actual resolved values (map(string)). Only claims resolvable at plan/apply time are included; runtime-only keys (e.g. environment, actor, ref) are omitted."
  value       = local.oidc_subject_claim_values
}

output "collaborators" {
  description = "Map of collaborators added to the repository, keyed by the same keys as the collaborators variable."
  value = {
    for k, v in github_repository_collaborator.this : k => {
      username      = v.username
      permission    = v.permission
      invitation_id = v.invitation_id
    }
  }
}

output "teams" {
  description = "Map of teams granted access to the repository, keyed by the same keys as the teams variable."
  value = {
    for k, v in github_team_repository.this : k => {
      team_id    = v.team_id
      permission = v.permission
    }
  }
}

output "environments" {
  description = "Map of environment keys to their submodule outputs, keyed by the same keys as the environments variable."
  value       = module.environment
}

output "rulesets" {
  description = "Map of ruleset keys to their submodule outputs, keyed by the same keys as the rulesets variable."
  value       = module.ruleset
}
