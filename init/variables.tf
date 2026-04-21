# Typed adopter inputs. Every variable carries a validation block; invalid
# values are rejected by `terraform apply` with a clear error message.
#
# The wrapper shell (../init-fleet.sh) prompts for any variable whose value
# in inputs.auto.tfvars is still the sentinel "__PROMPT__" and writes the
# filled-in values back before invoking apply.

variable "fleet_name" {
  description = "Short fleet slug; used in resource names. Lowercase alnum, starting with a letter, 2-12 chars."
  type        = string
  validation {
    condition     = can(regex("^[a-z][a-z0-9]{1,11}$", var.fleet_name))
    error_message = "fleet_name must match ^[a-z][a-z0-9]{1,11}$ (2-12 chars, lowercase alnum, letter first)."
  }
}

variable "fleet_display_name" {
  description = "Human-friendly fleet name (appears in README and Grafana)."
  type        = string
  validation {
    condition     = length(var.fleet_display_name) > 0
    error_message = "fleet_display_name must be non-empty."
  }
}

variable "tenant_id" {
  description = "Entra tenant GUID."
  type        = string
  validation {
    condition     = can(regex("^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$", var.tenant_id))
    error_message = "tenant_id must be a GUID."
  }
}

variable "github_org" {
  description = "GitHub org or user that owns the fleet repo."
  type        = string
  validation {
    # GitHub org/user rules: 1-39 chars, alnum at both ends, single hyphens
    # between alnum segments (no leading/trailing hyphen, no `--`).
    condition     = length(var.github_org) <= 39 && can(regex("^[A-Za-z0-9]+(-[A-Za-z0-9]+)*$", var.github_org))
    error_message = "github_org must be 1-39 characters of letters or digits, with single hyphens only between alphanumeric segments."
  }
}

variable "github_repo" {
  description = "Name of the fleet repo on GitHub."
  type        = string
  default     = "platform-fleet"
  validation {
    condition     = can(regex("^[A-Za-z0-9._-]+$", var.github_repo))
    error_message = "github_repo must match ^[A-Za-z0-9._-]+$."
  }
}

variable "codeowners_owner" {
  description = <<-EOT
    CODEOWNERS owner for the default (`*`) rule. One of:
      - `<org>/<team>`  — e.g. `acme/platform-engineers` (org-owned repo with a team)
      - `<user>`        — e.g. `octocat`                 (personal or fallback)
    Leave empty to default to `@${"$"}{github_org}`, which resolves for both
    user-owned and org-owned repos without requiring a pre-existing team.
  EOT
  type        = string
  default     = ""
  validation {
    # Either empty (fall back to github_org) or a valid org/team or user.
    # Team form: `<org>/<team>`; user form: `<user>`.
    condition = (
      var.codeowners_owner == "" ||
      can(regex("^[A-Za-z0-9]+(-[A-Za-z0-9]+)*(/[A-Za-z0-9][A-Za-z0-9._-]*)?$", var.codeowners_owner))
    )
    error_message = "codeowners_owner must be empty, `<user>`, or `<org>/<team>` (alnum/hyphen segments)."
  }
}

variable "team_template_repo" {
  description = "Name of the team template repo on GitHub."
  type        = string
  default     = "team-repo-template"
  validation {
    condition     = can(regex("^[A-Za-z0-9._-]+$", var.team_template_repo))
    error_message = "team_template_repo must match ^[A-Za-z0-9._-]+$."
  }
}

variable "primary_region" {
  description = "Primary Azure region (e.g. eastus)."
  type        = string
  default     = "eastus"
  validation {
    condition     = can(regex("^[a-z0-9]+$", var.primary_region))
    error_message = "primary_region must be a lowercase-alnum Azure location short name."
  }
}

variable "sub_shared" {
  description = "Subscription GUID for shared resources (ACR, state, fleet KV)."
  type        = string
  validation {
    condition     = can(regex("^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$", var.sub_shared))
    error_message = "sub_shared must be a GUID."
  }
}

variable "sub_mgmt" {
  description = "Subscription GUID for the mgmt environment."
  type        = string
  validation {
    condition     = can(regex("^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$", var.sub_mgmt))
    error_message = "sub_mgmt must be a GUID."
  }
}

variable "sub_nonprod" {
  description = "Subscription GUID for the nonprod environment."
  type        = string
  validation {
    condition     = can(regex("^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$", var.sub_nonprod))
    error_message = "sub_nonprod must be a GUID."
  }
}

variable "sub_prod" {
  description = "Subscription GUID for the prod environment."
  type        = string
  validation {
    condition     = can(regex("^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$", var.sub_prod))
    error_message = "sub_prod must be a GUID."
  }
}

variable "dns_fleet_root" {
  description = "DNS root zone under which per-cluster private zones are created (e.g. int.acme.example)."
  type        = string
  validation {
    condition     = can(regex("^[a-z0-9]([a-z0-9-]*[a-z0-9])?(\\.[a-z0-9]([a-z0-9-]*[a-z0-9])?)+$", var.dns_fleet_root))
    error_message = "dns_fleet_root must be a lowercase DNS name like int.acme.example."
  }
}

variable "template_commit" {
  description = "Template repo commit SHA at init time (populated by the wrapper shell; leave empty for local runs)."
  type        = string
  default     = "unknown"
}

# ---- networking (PLAN §3.4) -------------------------------------------------
#
# Four repo-owned VNets — mgmt (bootstrap/fleet) and one per env-region
# (bootstrap/environment). Minimum /20 per VNet. Per-cluster /28 api +
# /25 nodes subnets are carved by Stage 1 using `networking.subnet_slot`
# in each cluster.yaml (/20 → 16 slots; /21 → 12; /22 → 4; two-pool
# layout, see PLAN §3.4).
#
# BYO: hub VNet resource id + four central private DNS zone resource ids.
# Every PE created by the repo (tfstate SA, fleet KV, fleet ACR, Grafana)
# registers into the matching central zone — the repo never creates a
# zone itself.
#
# Pod CIDRs live in CGNAT (100.64.0.0/10). Each env-region reserves a
# /12 slice via its `pod_cidr_slot` (0..15, unique fleet-wide); each
# cluster inside the region gets a /16 at
# 100.[64 + pod_cidr_slot*16 + cluster.subnet_slot].0.0/16. The 3 vars
# below seed the initial mgmt/nonprod/prod slots; widen by editing
# `clusters/_fleet.yaml` post-init.

variable "networking_hub_resource_id" {
  description = "Full ARM resource id of the adopter-owned hub VNet. Every env VNet hub-peers to it; bootstrap/fleet's mgmt VNet hub-peers too."
  type        = string
  validation {
    condition     = can(regex("^/subscriptions/[0-9a-fA-F-]{36}/resourceGroups/[^/]+/providers/Microsoft\\.Network/virtualNetworks/[^/]+$", var.networking_hub_resource_id))
    error_message = "networking_hub_resource_id must be a full /subscriptions/.../providers/Microsoft.Network/virtualNetworks/<name> resource id."
  }
}

variable "networking_pdz_blob" {
  description = "Full ARM resource id of the BYO privatelink.blob.core.windows.net private DNS zone (tfstate SA PE registers here)."
  type        = string
  validation {
    condition     = can(regex("^/subscriptions/[0-9a-fA-F-]{36}/resourceGroups/[^/]+/providers/Microsoft\\.Network/privateDnsZones/privatelink\\.blob\\.core\\.windows\\.net$", var.networking_pdz_blob))
    error_message = "networking_pdz_blob must end in /privateDnsZones/privatelink.blob.core.windows.net."
  }
}

variable "networking_pdz_vaultcore" {
  description = "Full ARM resource id of the BYO privatelink.vaultcore.azure.net private DNS zone (fleet KV PE registers here)."
  type        = string
  validation {
    condition     = can(regex("^/subscriptions/[0-9a-fA-F-]{36}/resourceGroups/[^/]+/providers/Microsoft\\.Network/privateDnsZones/privatelink\\.vaultcore\\.azure\\.net$", var.networking_pdz_vaultcore))
    error_message = "networking_pdz_vaultcore must end in /privateDnsZones/privatelink.vaultcore.azure.net."
  }
}

variable "networking_pdz_azurecr" {
  description = "Full ARM resource id of the BYO privatelink.azurecr.io private DNS zone (fleet ACR PE + runner per-pool ACR PEs register here)."
  type        = string
  validation {
    condition     = can(regex("^/subscriptions/[0-9a-fA-F-]{36}/resourceGroups/[^/]+/providers/Microsoft\\.Network/privateDnsZones/privatelink\\.azurecr\\.io$", var.networking_pdz_azurecr))
    error_message = "networking_pdz_azurecr must end in /privateDnsZones/privatelink.azurecr.io."
  }
}

variable "networking_pdz_grafana" {
  description = "Full ARM resource id of the BYO privatelink.grafana.azure.com private DNS zone (per-env Grafana PE registers here)."
  type        = string
  validation {
    condition     = can(regex("^/subscriptions/[0-9a-fA-F-]{36}/resourceGroups/[^/]+/providers/Microsoft\\.Network/privateDnsZones/privatelink\\.grafana\\.azure\\.com$", var.networking_pdz_grafana))
    error_message = "networking_pdz_grafana must end in /privateDnsZones/privatelink.grafana.azure.com."
  }
}

# Address spaces — one per repo-owned VNet. Each: valid CIDR, RFC1918,
# /20 or wider. Non-overlap across the four is enforced below via a
# composite validation on networking_mgmt_address_space (last-declared
# wins; see `can(cidrsubnet(...))` trick — compares normalized network
# forms).

variable "networking_mgmt_address_space" {
  description = "Address space (CIDR) of the mgmt VNet owned by bootstrap/fleet. RFC1918, /20 or wider. Two /26s reserved (snet-pe-shared, snet-runners)."
  type        = string
  validation {
    condition     = can(cidrnetmask(var.networking_mgmt_address_space))
    error_message = "networking_mgmt_address_space must be a valid CIDR (e.g. 10.50.0.0/20)."
  }
  validation {
    condition     = !can(cidrnetmask(var.networking_mgmt_address_space)) || try(tonumber(split("/", var.networking_mgmt_address_space)[1]), 0) <= 20
    error_message = "networking_mgmt_address_space must be /20 or wider (≤20)."
  }
  validation {
    condition     = can(regex("^(10\\.|172\\.(1[6-9]|2[0-9]|3[0-1])\\.|192\\.168\\.)", var.networking_mgmt_address_space))
    error_message = "networking_mgmt_address_space must be RFC1918 (10.0.0.0/8, 172.16.0.0/12, or 192.168.0.0/16)."
  }
}

variable "networking_env_mgmt_eastus_address_space" {
  description = "Address space (CIDR) of the mgmt-env VNet in primary_region. RFC1918, /20 or wider."
  type        = string
  validation {
    condition     = can(cidrnetmask(var.networking_env_mgmt_eastus_address_space))
    error_message = "networking_env_mgmt_eastus_address_space must be a valid CIDR."
  }
  validation {
    condition     = !can(cidrnetmask(var.networking_env_mgmt_eastus_address_space)) || try(tonumber(split("/", var.networking_env_mgmt_eastus_address_space)[1]), 0) <= 20
    error_message = "networking_env_mgmt_eastus_address_space must be /20 or wider (≤20)."
  }
  validation {
    condition     = can(regex("^(10\\.|172\\.(1[6-9]|2[0-9]|3[0-1])\\.|192\\.168\\.)", var.networking_env_mgmt_eastus_address_space))
    error_message = "networking_env_mgmt_eastus_address_space must be RFC1918."
  }
}

variable "networking_env_nonprod_eastus_address_space" {
  description = "Address space (CIDR) of the nonprod-env VNet in primary_region. RFC1918, /20 or wider."
  type        = string
  validation {
    condition     = can(cidrnetmask(var.networking_env_nonprod_eastus_address_space))
    error_message = "networking_env_nonprod_eastus_address_space must be a valid CIDR."
  }
  validation {
    condition     = !can(cidrnetmask(var.networking_env_nonprod_eastus_address_space)) || try(tonumber(split("/", var.networking_env_nonprod_eastus_address_space)[1]), 0) <= 20
    error_message = "networking_env_nonprod_eastus_address_space must be /20 or wider (≤20)."
  }
  validation {
    condition     = can(regex("^(10\\.|172\\.(1[6-9]|2[0-9]|3[0-1])\\.|192\\.168\\.)", var.networking_env_nonprod_eastus_address_space))
    error_message = "networking_env_nonprod_eastus_address_space must be RFC1918."
  }
}

variable "networking_env_prod_eastus_address_space" {
  description = "Address space (CIDR) of the prod-env VNet in primary_region. RFC1918, /20 or wider. Must not overlap the other three repo-owned VNets."
  type        = string
  validation {
    condition     = can(cidrnetmask(var.networking_env_prod_eastus_address_space))
    error_message = "networking_env_prod_eastus_address_space must be a valid CIDR."
  }
  validation {
    condition     = !can(cidrnetmask(var.networking_env_prod_eastus_address_space)) || try(tonumber(split("/", var.networking_env_prod_eastus_address_space)[1]), 0) <= 20
    error_message = "networking_env_prod_eastus_address_space must be /20 or wider (≤20)."
  }
  validation {
    condition     = can(regex("^(10\\.|172\\.(1[6-9]|2[0-9]|3[0-1])\\.|192\\.168\\.)", var.networking_env_prod_eastus_address_space))
    error_message = "networking_env_prod_eastus_address_space must be RFC1918."
  }
  # Non-overlap across all four repo-owned VNets. Compare normalized
  # network forms via cidrsubnet(_, 0, 0). Only catches exact-match
  # duplication when all four are the same prefix length; partial
  # overlap across mixed prefix lengths is flagged as a known gap in
  # docs/networking.md (operator-side CIDR planning). Guarded with
  # alltrue+can so this rule only fires once every input is a valid
  # CIDR — otherwise the per-field CIDR-syntax rule above fires first.
  validation {
    condition = !alltrue([
      can(cidrnetmask(var.networking_mgmt_address_space)),
      can(cidrnetmask(var.networking_env_mgmt_eastus_address_space)),
      can(cidrnetmask(var.networking_env_nonprod_eastus_address_space)),
      can(cidrnetmask(var.networking_env_prod_eastus_address_space)),
      ]) || length(distinct([
        cidrsubnet(var.networking_mgmt_address_space, 0, 0),
        cidrsubnet(var.networking_env_mgmt_eastus_address_space, 0, 0),
        cidrsubnet(var.networking_env_nonprod_eastus_address_space, 0, 0),
        cidrsubnet(var.networking_env_prod_eastus_address_space, 0, 0),
    ])) == 4
    error_message = "The four repo-owned VNet address spaces (mgmt + mgmt/nonprod/prod env in primary_region) must be distinct."
  }
}

# Pod-CIDR slot allocation per env-region (PLAN §3.4). Each slot reserves
# a /12 inside the fleet's CGNAT (100.64.0.0/10) pod space; every cluster
# in the env-region is assigned a /16 at
# 100.[64 + pod_cidr_slot*16 + cluster.subnet_slot].0.0/16. Slots must be
# unique across every declared env-region (distinctness enforced below
# on the prod slot, which is declared last).

variable "networking_env_mgmt_eastus_pod_cidr_slot" {
  description = "CGNAT pod-CIDR slot (0..15) for the mgmt env in primary_region. Each slot reserves a /12 inside 100.64.0.0/10 for cluster pod /16s."
  type        = number
  default     = 0
  validation {
    condition     = var.networking_env_mgmt_eastus_pod_cidr_slot >= 0 && var.networking_env_mgmt_eastus_pod_cidr_slot <= 15 && floor(var.networking_env_mgmt_eastus_pod_cidr_slot) == var.networking_env_mgmt_eastus_pod_cidr_slot
    error_message = "networking_env_mgmt_eastus_pod_cidr_slot must be an integer in [0, 15]."
  }
}

variable "networking_env_nonprod_eastus_pod_cidr_slot" {
  description = "CGNAT pod-CIDR slot (0..15) for the nonprod env in primary_region. Must differ from every other declared env-region's slot."
  type        = number
  default     = 1
  validation {
    condition     = var.networking_env_nonprod_eastus_pod_cidr_slot >= 0 && var.networking_env_nonprod_eastus_pod_cidr_slot <= 15 && floor(var.networking_env_nonprod_eastus_pod_cidr_slot) == var.networking_env_nonprod_eastus_pod_cidr_slot
    error_message = "networking_env_nonprod_eastus_pod_cidr_slot must be an integer in [0, 15]."
  }
}

variable "networking_env_prod_eastus_pod_cidr_slot" {
  description = "CGNAT pod-CIDR slot (0..15) for the prod env in primary_region. Must differ from every other declared env-region's slot."
  type        = number
  default     = 2
  validation {
    condition     = var.networking_env_prod_eastus_pod_cidr_slot >= 0 && var.networking_env_prod_eastus_pod_cidr_slot <= 15 && floor(var.networking_env_prod_eastus_pod_cidr_slot) == var.networking_env_prod_eastus_pod_cidr_slot
    error_message = "networking_env_prod_eastus_pod_cidr_slot must be an integer in [0, 15]."
  }
  # Cross-field distinctness — every declared env-region must pick a
  # distinct slot. Declared on `prod` (the last of the three vars) so
  # that all three values are in scope at validation time.
  validation {
    condition = length(distinct([
      var.networking_env_mgmt_eastus_pod_cidr_slot,
      var.networking_env_nonprod_eastus_pod_cidr_slot,
      var.networking_env_prod_eastus_pod_cidr_slot,
    ])) == 3
    error_message = "The three env-region pod_cidr_slot values (mgmt/nonprod/prod in primary_region) must be distinct."
  }
}
