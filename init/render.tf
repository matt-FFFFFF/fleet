# Rendering resources. Each local_file writes into the parent repo (../),
# overwriting any existing content. `local_file` defaults (0777 dir perms,
# 0777 file perms masked by umask) are fine for generated text assets here.
#
# The .fleet-initialized marker is rendered LAST in dependency order by
# referencing the other resources' ids in its content, which makes it
# impossible for the marker to appear without the generated files.

locals {
  # Single rendering context — kept as one map so changes to variables flow
  # through to every template without needing to thread each key.
  ctx = {
    fleet_name         = var.fleet_name
    fleet_display_name = var.fleet_display_name
    tenant_id          = var.tenant_id
    github_org         = var.github_org
    github_repo        = var.github_repo
    team_template_repo = var.team_template_repo
    primary_region     = var.primary_region
    sub_shared         = var.sub_shared
    sub_mgmt           = var.sub_mgmt
    sub_nonprod        = var.sub_nonprod
    sub_prod           = var.sub_prod
    dns_fleet_root     = var.dns_fleet_root
    # Networking (PLAN §3.4) — BYO hub + PDZs, plus four repo-owned VNets
    # (mgmt + one per env in primary_region).
    networking_hub_resource_id                  = var.networking_hub_resource_id
    networking_pdz_blob                         = var.networking_pdz_blob
    networking_pdz_vaultcore                    = var.networking_pdz_vaultcore
    networking_pdz_azurecr                      = var.networking_pdz_azurecr
    networking_pdz_grafana                      = var.networking_pdz_grafana
    networking_mgmt_address_space               = var.networking_mgmt_address_space
    networking_env_mgmt_eastus_address_space    = var.networking_env_mgmt_eastus_address_space
    networking_env_nonprod_eastus_address_space = var.networking_env_nonprod_eastus_address_space
    networking_env_prod_eastus_address_space    = var.networking_env_prod_eastus_address_space
    # CODEOWNERS default-rule owner. Empty input falls back to the org/user
    # itself (guaranteed to resolve); adopters can override with a team spec
    # like `acme/platform-engineers`.
    codeowners_owner = var.codeowners_owner != "" ? var.codeowners_owner : var.github_org
  }
}

resource "local_file" "fleet_yaml" {
  filename = "${path.module}/../clusters/_fleet.yaml"
  content  = templatefile("${path.module}/templates/_fleet.yaml.tftpl", local.ctx)
}

resource "local_file" "codeowners" {
  filename = "${path.module}/../.github/CODEOWNERS"
  content  = templatefile("${path.module}/templates/CODEOWNERS.tftpl", local.ctx)
}

resource "local_file" "readme" {
  filename = "${path.module}/../README.md"
  content  = templatefile("${path.module}/templates/README.md.tftpl", local.ctx)
}

resource "local_file" "marker" {
  filename = "${path.module}/../.fleet-initialized"
  content = yamlencode({
    # Hashes of the rendered artefacts prove the marker was produced AFTER
    # and BY the same apply run — a corrupted or partial render would bump
    # these and `terraform apply` would re-reconcile.
    initialized_at  = timestamp()
    template_commit = var.template_commit
    fleet_name      = var.fleet_name
    rendered_files_sha1 = {
      fleet_yaml = local_file.fleet_yaml.content_sha1
      codeowners = local_file.codeowners.content_sha1
      readme     = local_file.readme.content_sha1
    }
  })
}
