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
  description = <<-EOT
    Primary Azure region (e.g. eastus). Used as the single region for the
    three initial repo-owned env-region VNets (mgmt, nonprod, prod) and as
    `envs.mgmt.location` (the location for mgmt-only non-cluster resources:
    fleet resource groups, fleet-meta UAMI, fleet ACR). Adopters add more
    regions by editing _fleet.yaml post-init.
  EOT
  type        = string
  default     = "eastus"
  validation {
    condition     = can(regex("^[a-z0-9]+$", var.primary_region))
    error_message = "primary_region must be a lowercase-alnum Azure location short name."
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

# ---- networking (PLAN §3.1 / §3.4) — central BYO references ----------------
#
# Four central private DNS zones — all BYO, never created by this repo.
# Every PE created by the repo (tfstate SA, fleet KV, fleet ACR, env
# Grafana) registers into the matching central zone.
#
# Pod CIDRs: every cluster uses the same CGNAT `/16` (100.64.0.0/16),
# hard-coded in `modules/aks-cluster/main.tf`. Rationale: pod IPs are
# non-routable (CNI Overlay + Cilium); cross-cluster disambiguation is
# already provided by `_ResourceId` / cluster name in every Log
# Analytics and Prometheus query.

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

# Address spaces — one per repo-owned env-region VNet. Each: valid CIDR,
# RFC1918, /20 or wider, strictly aligned. Pairwise non-overlap enforced
# below on `networking_env_prod_address_space` (last-declared wins).

variable "environments" {
  description = <<-EOT
    Per-env identity + networking inputs, keyed by env name. One entry
    per environment the adopter wants; the map is free-form (any env
    names), but the key `mgmt` is required — it identifies the
    management env (home of bootstrap/fleet's fleet-plane subnets and
    the mgmt cluster plane). Typical shape is `{mgmt, nonprod, prod}`,
    matching the default below; adopters add `dev`, `stage`, `qa`,
    `preprod`, etc. by editing `init/inputs.auto.tfvars` before running
    `init-fleet.sh`.

    Each entry carries:
      subscription_id     GUID of the env's Azure subscription.
      address_space       VNet CIDR in `primary_region`. RFC1918, /20
                          or wider, strictly aligned. Minimum /20.
                          Per-cluster /28 api + /25 nodes subnets are
                          carved by Stage 1 (see PLAN §3.4). For
                          env=mgmt the VNet additionally hosts
                          bootstrap/fleet's snet-pe-fleet (/26) and
                          snet-runners (/23) at the HIGH end.
      hub_network_resource_id
                          (nullable on every env, including mgmt) ARM
                          resource id of the adopter-owned hub VNet
                          this env-region peers to. Rendered into
                          `networking.envs.<env>.regions.<primary_region>.hub_network_resource_id`.
                          Null ⇒ opt out of hub peering for this env-
                          region (adopter-managed routing); the tftpl
                          emits YAML `null`. Mgmt↔env peering is
                          implicit: bootstrap/environment iterates
                          `networking.envs.mgmt.regions` same-region-
                          else-first (no selector variable needed).

    Pairwise non-overlap is enforced across every address_space below.
    Every entry's address_space is rendered as a YAML list (single
    element) under
    `networking.envs.<env>.regions.<primary_region>.address_space`.
  EOT
  type = map(object({
    subscription_id         = string
    address_space           = string
    hub_network_resource_id = optional(string)
  }))
  default = {
    mgmt = {
      subscription_id         = "__PROMPT__"
      address_space           = "10.50.0.0/20"
      hub_network_resource_id = "__PROMPT__"
    }
    nonprod = {
      subscription_id         = "__PROMPT__"
      address_space           = "10.70.0.0/20"
      hub_network_resource_id = "__PROMPT__"
    }
    prod = {
      subscription_id         = "__PROMPT__"
      address_space           = "10.80.0.0/20"
      hub_network_resource_id = "__PROMPT__"
    }
  }

  # Structural: `mgmt` must be present.
  validation {
    condition     = contains(keys(var.environments), "mgmt")
    error_message = "environments must contain a `mgmt` entry (the management env name is fixed; downstream bootstrap/stages key on the literal string `mgmt`)."
  }

  # Env names: lowercase alnum, 2-12 chars (same rule as fleet_name;
  # used in resource names and yaml keys).
  validation {
    condition     = alltrue([for name in keys(var.environments) : can(regex("^[a-z][a-z0-9]{1,11}$", name))])
    error_message = "Every environments key must match ^[a-z][a-z0-9]{1,11}$ (2-12 chars, lowercase alnum, letter first)."
  }

  # Every subscription_id is a GUID (or the __PROMPT__ sentinel — the
  # wrapper shell substitutes those before apply, but default-carrying
  # entries would otherwise fail validation on `terraform plan` during
  # selftest runs that use the file's default). Because `__PROMPT__`
  # never reaches `terraform apply` (init-fleet.sh rewrites it first)
  # we enforce GUID strictly; test-time callers supply real GUIDs.
  validation {
    condition     = alltrue([for cfg in values(var.environments) : can(regex("^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$", cfg.subscription_id))])
    error_message = "environments.<env>.subscription_id must be a GUID (init-fleet.sh substitutes __PROMPT__ sentinels on the TTY before apply)."
  }

  # CIDR syntax + RFC1918 + /20-or-wider + strict alignment — one
  # alltrue per rule so the error message names the rule that fired.
  validation {
    condition     = alltrue([for cfg in values(var.environments) : can(cidrnetmask(cfg.address_space))])
    error_message = "Every environments.<env>.address_space must be a valid CIDR (e.g. 10.50.0.0/20)."
  }
  validation {
    condition = alltrue([
      for cfg in values(var.environments) :
      !can(cidrnetmask(cfg.address_space)) || tonumber(split("/", cfg.address_space)[1]) <= 20
    ])
    error_message = "Every environments.<env>.address_space must be /20 or wider (prefix ≤20)."
  }
  validation {
    condition = alltrue([
      for cfg in values(var.environments) :
      can(regex("^(10\\.|172\\.(1[6-9]|2[0-9]|3[0-1])\\.|192\\.168\\.)", cfg.address_space))
    ])
    error_message = "Every environments.<env>.address_space must be RFC1918 (10.0.0.0/8, 172.16.0.0/12, or 192.168.0.0/16)."
  }
  validation {
    condition = alltrue([
      for cfg in values(var.environments) :
      !can(cidrnetmask(cfg.address_space)) || cidrhost(cfg.address_space, 0) == split("/", cfg.address_space)[0]
    ])
    error_message = "Every environments.<env>.address_space must be strictly aligned on its prefix (no host bits set; e.g. `10.50.0.0/20`, not `10.50.0.1/20`). `config-loader/load.sh` derives subnet CIDRs with Python `ipaddress.ip_network(..., strict=True)` which rejects misaligned inputs."
  }

  # Pairwise non-overlap across every env's address_space. For CIDR-
  # aligned blocks, A and B overlap iff the network address of each,
  # re-masked at `min(prefix_A, prefix_B)`, is equal (one contains
  # the other). Catches both exact duplication and partial overlap
  # across mixed prefix lengths (e.g. 10.50.0.0/20 vs 10.50.0.0/21).
  # Guarded with alltrue+can so this rule only fires once every
  # input is a valid CIDR — otherwise the per-field CIDR-syntax rule
  # above fires first. `setproduct` yields every ordered pair; we
  # skip the diagonal (a == b) and rely on symmetric comparison.
  validation {
    condition = !alltrue([for cfg in values(var.environments) : can(cidrnetmask(cfg.address_space))]) || alltrue([
      for pair in setproduct(keys(var.environments), keys(var.environments)) :
      pair[0] == pair[1] ? true : (
        cidrsubnet("${split("/", var.environments[pair[0]].address_space)[0]}/${min(tonumber(split("/", var.environments[pair[0]].address_space)[1]), tonumber(split("/", var.environments[pair[1]].address_space)[1]))}", 0, 0)
        !=
        cidrsubnet("${split("/", var.environments[pair[1]].address_space)[0]}/${min(tonumber(split("/", var.environments[pair[0]].address_space)[1]), tonumber(split("/", var.environments[pair[1]].address_space)[1]))}", 0, 0)
      )
    ])
    error_message = "All environments.<env>.address_space values must be pairwise disjoint (no exact match and no partial overlap across mixed prefix lengths)."
  }

  # Hub resource id shape — only validated when set (nullable on every
  # env, including mgmt; null = opt out of hub peering for that env-
  # region, adopter-managed routing).
  validation {
    condition = alltrue([
      for cfg in values(var.environments) :
      cfg.hub_network_resource_id == null ||
      can(regex("^/subscriptions/[0-9a-fA-F-]{36}/resourceGroups/[^/]+/providers/Microsoft\\.Network/virtualNetworks/[^/]+$", cfg.hub_network_resource_id))
    ])
    error_message = "environments.<env>.hub_network_resource_id must be a full /subscriptions/.../providers/Microsoft.Network/virtualNetworks/<name> resource id when set (null opts out of hub peering for that env-region)."
  }
}
