# -----------------------------------------------------------------------------
# Repository collaborators (non-authoritative)
# -----------------------------------------------------------------------------

resource "github_repository_collaborator" "this" {
  for_each = var.collaborators

  repository = local.repository
  username   = each.value.username
  permission = each.value.permission
}

# -----------------------------------------------------------------------------
# Team repository access (non-authoritative)
# -----------------------------------------------------------------------------

resource "github_team_repository" "this" {
  for_each = var.teams

  repository = local.repository
  team_id    = each.value.team_id
  permission = each.value.permission
}
