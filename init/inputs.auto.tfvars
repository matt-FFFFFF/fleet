# Adopter input values for the fleet template.
#
# How this file is used:
#   1. Run `../init-fleet.sh` from the repo root. For every variable below
#      whose value is still "__PROMPT__", the wrapper prompts you on the
#      terminal and writes your answer back into this file.
#   2. You may pre-fill any value here to skip its prompt. This is how CI
#      (see .github/workflows/template-selftest.yaml) drives the flow
#      non-interactively via an override tfvars file.
#   3. Once all values are set, the wrapper invokes `terraform apply` in
#      this directory; Terraform validates each variable and renders
#      clusters/_fleet.yaml, .github/CODEOWNERS, README.md, and the
#      .fleet-initialized marker.
#
# After a successful apply the wrapper deletes this entire init/ directory
# along with init-fleet.sh itself, so editing these values post-init has no
# effect — edit the rendered clusters/_fleet.yaml directly instead.

# ---- identity ---------------------------------------------------------------

fleet_name         = "__PROMPT__" # short slug, lowercase alnum, 2-12 chars (used in resource names)
fleet_display_name = "__PROMPT__" # human-friendly (README + Grafana)
tenant_id          = "__PROMPT__" # Entra tenant GUID

# ---- GitHub -----------------------------------------------------------------

github_org         = "__PROMPT__"
github_repo        = "__PROMPT__"         # fleet repo name
team_template_repo = "__PROMPT__"         # team template repo name
codeowners_owner   = ""                   # CODEOWNERS owner: empty → @<github_org>; else `<org>/<team>` or `<user>`

# ---- Azure ------------------------------------------------------------------

primary_region = "eastus"

sub_shared  = "__PROMPT__" # subscription GUID — shared (ACR / tfstate / fleet KV)
sub_mgmt    = "__PROMPT__" # subscription GUID — mgmt environment
sub_nonprod = "__PROMPT__" # subscription GUID — nonprod environment
sub_prod    = "__PROMPT__" # subscription GUID — prod environment

# ---- DNS --------------------------------------------------------------------

dns_fleet_root = "__PROMPT__" # e.g. int.acme.example — parent of every per-cluster private zone
