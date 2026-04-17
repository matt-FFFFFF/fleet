output "next_steps" {
  description = "What the adopter should do after init completes."
  value       = <<-EOT

    Fleet initialized as "${var.fleet_display_name}" (slug: ${var.fleet_name}).

    Rendered:
      - clusters/_fleet.yaml
      - .github/CODEOWNERS
      - README.md
      - .fleet-initialized

    The wrapper shell (init-fleet.sh) will now remove the init/ machinery.
    Next:
      git status && git diff
      git add -A && git commit -m 'chore: initialize fleet from template'
      # then follow docs/adoption.md → terraform/bootstrap/fleet
  EOT
}
