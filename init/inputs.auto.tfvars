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
github_repo        = "__PROMPT__" # fleet repo name
team_template_repo = "__PROMPT__" # team template repo name
codeowners_owner   = ""           # CODEOWNERS owner: empty → @<github_org>; else `<org>/<team>` or `<user>`

# ---- Azure ------------------------------------------------------------------

primary_region = "eastus"

sub_shared = "__PROMPT__" # subscription GUID — shared (ACR / tfstate / fleet KV)

# ---- DNS --------------------------------------------------------------------

dns_fleet_root = "__PROMPT__" # e.g. int.acme.example — parent of every per-cluster private zone

# ---- Networking: central BYO private DNS zones (PLAN §3.4) ------------------
#
# BYO privatelink zones — never created by this repo, only referenced by id.
# Every PE (tfstate SA, fleet KV, fleet ACR, env Grafana) registers into the
# matching central zone.

networking_pdz_blob      = "__PROMPT__" # BYO privatelink.blob.core.windows.net zone id
networking_pdz_vaultcore = "__PROMPT__" # BYO privatelink.vaultcore.azure.net zone id
networking_pdz_azurecr   = "__PROMPT__" # BYO privatelink.azurecr.io zone id
networking_pdz_grafana   = "__PROMPT__" # BYO privatelink.grafana.azure.com zone id

# ---- Environments (PLAN §3.1 / §3.4) ----------------------------------------
#
# Per-env identity + networking, keyed by env name. Edit this map directly:
# add entries (e.g. `dev`, `stage`, `qa`) as needed, remove any you don't
# want. The init-fleet.sh prompt flow does not walk nested map values —
# fill in GUIDs and hub resource IDs here before running init, or after a
# first selftest run.
#
# Each entry:
#   subscription_id           Azure subscription GUID for this env.
#   address_space             VNet CIDR in `primary_region`. RFC1918, /20
#                             or wider, strictly aligned. Minimum /20.
#                             Per-cluster subnets carved by Stage 1.
#   hub_resource_id           (non-mgmt only) ARM id of the adopter hub
#                             VNet this env peers to. MUST be null/omitted
#                             on mgmt.
#   mgmt_peering_target_env   (mgmt only, default "prod") name of the
#                             non-mgmt env whose hub the mgmt VNet peers
#                             into.
#
# Minimum shape: one entry keyed `mgmt` plus at least one non-mgmt env.
# Pod CIDR is the same /16 in every cluster (100.64.0.0/16, hard-coded in
# modules/aks-cluster). Pod IPs are non-routable via CNI Overlay + Cilium;
# cross-cluster disambiguation comes from _ResourceId / cluster name.

environments = {
  mgmt = {
    subscription_id         = "__PROMPT__" # GUID — mgmt subscription
    address_space           = "10.50.0.0/20"
    mgmt_peering_target_env = "prod"
  }
  nonprod = {
    subscription_id = "__PROMPT__" # GUID — nonprod subscription
    address_space   = "10.70.0.0/20"
    hub_resource_id = "__PROMPT__" # /subscriptions/.../virtualNetworks/<vnet-hub-nonprod>
  }
  prod = {
    subscription_id = "__PROMPT__" # GUID — prod subscription
    address_space   = "10.80.0.0/20"
    hub_resource_id = "__PROMPT__" # /subscriptions/.../virtualNetworks/<vnet-hub-prod>
  }
}
