variable "collaborators" {
  description = <<DESCRIPTION
Map of collaborators to add to the repository.
The map key is an arbitrary identifier to avoid known-after-apply issues.

- `username` - The GitHub username of the collaborator.
- `permission` - The permission to grant. Built-in levels are: `pull`, `triage`, `push`,
  `maintain`, `admin`. Custom organization repository role names are also supported.
  Defaults to `push`.
DESCRIPTION
  type = map(object({
    username   = string
    permission = optional(string, "push")
  }))
  default  = {}
  nullable = false
}

variable "teams" {
  description = <<DESCRIPTION
Map of teams to grant access to the repository.
The map key is an arbitrary identifier to avoid known-after-apply issues.

- `team_id` - The ID or slug of the team.
- `permission` - The permission to grant. Must be one of: `pull`, `triage`, `push`,
  `maintain`, `admin`, or the name of an existing custom repository role within the
  organisation. Defaults to `push`.
DESCRIPTION
  type = map(object({
    team_id    = string
    permission = optional(string, "push")
  }))
  default  = {}
  nullable = false
}
