output "ruleset" {
  description = "The repository ruleset resource."
  value = {
    id          = github_repository_ruleset.this.id
    node_id     = github_repository_ruleset.this.node_id
    ruleset_id  = github_repository_ruleset.this.ruleset_id
    name        = github_repository_ruleset.this.name
    enforcement = github_repository_ruleset.this.enforcement
    target      = github_repository_ruleset.this.target
  }
}
