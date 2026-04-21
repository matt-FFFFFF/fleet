# init/ unit tests.
#
# The init module renders three adopter-facing artefacts (clusters/_fleet.yaml,
# .github/CODEOWNERS, README.md) plus a .fleet-initialized marker using the
# hashicorp/local provider. Here we:
#   1. Mock the `local` provider so assertions run against resource
#      attributes without touching the filesystem of the host running the
#      tests.
#   2. Assert that rendered content round-trips adopter identity correctly
#      (yaml structurally parses; known keys carry the expected values).
#   3. Exercise every `validation {}` block in variables.tf with a run block
#      whose sole purpose is `expect_failures`.

mock_provider "local" {}

# File-level defaults mirror .github/fixtures/adopter-test.tfvars so the
# test matrix matches the CI selftest. Individual run blocks override just
# the field under test.
variables {
  fleet_name         = "acme"
  fleet_display_name = "Acme Platform"
  tenant_id          = "11111111-1111-1111-1111-111111111111"
  github_org         = "acme-co"
  github_repo        = "platform-fleet"
  team_template_repo = "team-repo-template"
  primary_region     = "eastus"
  sub_shared         = "22222222-2222-2222-2222-222222222222"
  dns_fleet_root     = "int.acme.example"
  template_commit    = "deadbeefdeadbeefdeadbeefdeadbeefdeadbeef"

  networking_pdz_blob      = "/subscriptions/66666666-6666-6666-6666-666666666666/resourceGroups/rg-hub-dns/providers/Microsoft.Network/privateDnsZones/privatelink.blob.core.windows.net"
  networking_pdz_vaultcore = "/subscriptions/66666666-6666-6666-6666-666666666666/resourceGroups/rg-hub-dns/providers/Microsoft.Network/privateDnsZones/privatelink.vaultcore.azure.net"
  networking_pdz_azurecr   = "/subscriptions/66666666-6666-6666-6666-666666666666/resourceGroups/rg-hub-dns/providers/Microsoft.Network/privateDnsZones/privatelink.azurecr.io"
  networking_pdz_grafana   = "/subscriptions/66666666-6666-6666-6666-666666666666/resourceGroups/rg-hub-dns/providers/Microsoft.Network/privateDnsZones/privatelink.grafana.azure.com"

  environments = {
    mgmt = {
      subscription_id         = "33333333-3333-3333-3333-333333333333"
      address_space           = "10.50.0.0/20"
      mgmt_peering_target_env = "prod"
    }
    nonprod = {
      subscription_id = "44444444-4444-4444-4444-444444444444"
      address_space   = "10.70.0.0/20"
      hub_resource_id = "/subscriptions/66666666-6666-6666-6666-666666666666/resourceGroups/rg-hub/providers/Microsoft.Network/virtualNetworks/vnet-hub-nonprod-eastus"
    }
    prod = {
      subscription_id = "55555555-5555-5555-5555-555555555555"
      address_space   = "10.80.0.0/20"
      hub_resource_id = "/subscriptions/66666666-6666-6666-6666-666666666666/resourceGroups/rg-hub/providers/Microsoft.Network/virtualNetworks/vnet-hub-prod-eastus"
    }
  }
}

# ---- happy path: content round-trips fixture values ------------------------

run "render_happy_path_fleet_yaml" {
  command = apply

  # Each assert below re-runs `yamldecode(local_file.fleet_yaml.content)`.
  # `run` blocks do not support `locals{}` (only variables/module/providers/
  # assert/expect_failures/state_key/parallel/command/plan_options — see
  # https://developer.hashicorp.com/terraform/language/tests#run-blocks),
  # so there is no in-test way to hoist the decode. The cost is trivial:
  # local_file.fleet_yaml.content is a string attribute already in state
  # by the time assertions run, and yamldecode on ~60 lines is sub-ms.
  assert {
    condition     = yamldecode(local_file.fleet_yaml.content).fleet.name == "acme"
    error_message = "Rendered _fleet.yaml must carry fleet.name = var.fleet_name."
  }

  assert {
    condition     = yamldecode(local_file.fleet_yaml.content).fleet.tenant_id == "11111111-1111-1111-1111-111111111111"
    error_message = "Rendered _fleet.yaml must carry fleet.tenant_id = var.tenant_id."
  }

  assert {
    condition     = yamldecode(local_file.fleet_yaml.content).fleet.github_org == "acme-co"
    error_message = "Rendered _fleet.yaml must carry fleet.github_org = var.github_org."
  }

  # Per PLAN §3.1: `fleet.primary_region` is GONE. Location for mgmt-only
  # non-cluster resources lives at `envs.mgmt.location`; cluster-bearing
  # env-regions take their location from the networking.envs.<env>.regions
  # key.
  assert {
    condition     = !can(yamldecode(local_file.fleet_yaml.content).fleet.primary_region)
    error_message = "`fleet.primary_region` must NOT be rendered (removed in PLAN §3.1; replaced by envs.mgmt.location)."
  }

  assert {
    condition     = yamldecode(local_file.fleet_yaml.content).envs.mgmt.location == "eastus"
    error_message = "envs.mgmt.location must equal primary_region."
  }

  # Only the mgmt env carries a location; non-mgmt envs take their location
  # from the networking.envs.<env>.regions key.
  assert {
    condition = alltrue([
      !can(yamldecode(local_file.fleet_yaml.content).envs.nonprod.location),
      !can(yamldecode(local_file.fleet_yaml.content).envs.prod.location),
    ])
    error_message = "envs.<env>.location must only be emitted on the mgmt env."
  }

  assert {
    condition     = yamldecode(local_file.fleet_yaml.content).dns.fleet_root == "int.acme.example"
    error_message = "Rendered _fleet.yaml must carry dns.fleet_root = var.dns_fleet_root."
  }

  # Each env subscription id lands in the right slot under `envs`, sourced
  # from the `environments` map.
  assert {
    condition = alltrue([
      yamldecode(local_file.fleet_yaml.content).envs.mgmt.subscription_id == "33333333-3333-3333-3333-333333333333",
      yamldecode(local_file.fleet_yaml.content).envs.nonprod.subscription_id == "44444444-4444-4444-4444-444444444444",
      yamldecode(local_file.fleet_yaml.content).envs.prod.subscription_id == "55555555-5555-5555-5555-555555555555",
    ])
    error_message = "envs.<env>.subscription_id must come from var.environments[<env>].subscription_id."
  }

  # Top-level `environments:` is gone — replaced by `envs:` per PLAN §3.1.
  # (The input variable is `environments`, but it is emitted under `envs`.)
  assert {
    condition     = !can(yamldecode(local_file.fleet_yaml.content).environments)
    error_message = "Top-level `environments:` must NOT be rendered (renamed to `envs:` in PLAN §3.1)."
  }

  # acr.subscription_id + state.subscription_id both derive from sub_shared.
  assert {
    condition = alltrue([
      yamldecode(local_file.fleet_yaml.content).acr.subscription_id == "22222222-2222-2222-2222-222222222222",
      yamldecode(local_file.fleet_yaml.content).state.subscription_id == "22222222-2222-2222-2222-222222222222",
    ])
    error_message = "acr.subscription_id and state.subscription_id must both derive from var.sub_shared."
  }

  # AAD display names interpolate fleet_name.
  assert {
    condition     = yamldecode(local_file.fleet_yaml.content).aad.argocd.display_name == "acme-argocd"
    error_message = "aad.argocd.display_name must interpolate as <fleet_name>-argocd."
  }

  assert {
    condition     = yamldecode(local_file.fleet_yaml.content).aad.kargo.display_name == "acme-kargo"
    error_message = "aad.kargo.display_name must interpolate as <fleet_name>-kargo."
  }
}

# Open-map extension: adopter declares an extra `dev` env. The renderer
# must emit dev under both networking.hubs and networking.envs / envs
# without hard-coding env names.
run "render_open_map_extra_env" {
  command = apply

  variables {
    environments = {
      mgmt = {
        subscription_id         = "33333333-3333-3333-3333-333333333333"
        address_space           = "10.50.0.0/20"
        mgmt_peering_target_env = "prod"
      }
      dev = {
        subscription_id = "99999999-9999-9999-9999-999999999999"
        address_space   = "10.60.0.0/20"
        hub_resource_id = "/subscriptions/66666666-6666-6666-6666-666666666666/resourceGroups/rg-hub/providers/Microsoft.Network/virtualNetworks/vnet-hub-dev-eastus"
      }
      nonprod = {
        subscription_id = "44444444-4444-4444-4444-444444444444"
        address_space   = "10.70.0.0/20"
        hub_resource_id = "/subscriptions/66666666-6666-6666-6666-666666666666/resourceGroups/rg-hub/providers/Microsoft.Network/virtualNetworks/vnet-hub-nonprod-eastus"
      }
      prod = {
        subscription_id = "55555555-5555-5555-5555-555555555555"
        address_space   = "10.80.0.0/20"
        hub_resource_id = "/subscriptions/66666666-6666-6666-6666-666666666666/resourceGroups/rg-hub/providers/Microsoft.Network/virtualNetworks/vnet-hub-prod-eastus"
      }
    }
  }

  assert {
    condition = alltrue([
      yamldecode(local_file.fleet_yaml.content).envs.dev.subscription_id == "99999999-9999-9999-9999-999999999999",
      yamldecode(local_file.fleet_yaml.content).networking.envs.dev.regions.eastus.address_space == ["10.60.0.0/20"],
      yamldecode(local_file.fleet_yaml.content).networking.hubs.dev.regions.eastus.resource_id == "/subscriptions/66666666-6666-6666-6666-666666666666/resourceGroups/rg-hub/providers/Microsoft.Network/virtualNetworks/vnet-hub-dev-eastus",
    ])
    error_message = "Extra env entries must fan out into envs.<env>, networking.envs.<env>, and networking.hubs.<env> uniformly."
  }

  # dev is not mgmt — must not carry location or mgmt_environment_for_vnet_peering.
  assert {
    condition = alltrue([
      !can(yamldecode(local_file.fleet_yaml.content).envs.dev.location),
      !can(yamldecode(local_file.fleet_yaml.content).networking.envs.dev.regions.eastus.mgmt_environment_for_vnet_peering),
    ])
    error_message = "Non-mgmt envs must not carry location or mgmt_environment_for_vnet_peering."
  }
}

run "codeowners_falls_back_to_github_org" {
  command = apply

  # Leave codeowners_owner at its default ""; expect fallback to github_org.
  assert {
    condition     = strcontains(local_file.codeowners.content, "@acme-co")
    error_message = "Empty codeowners_owner must fall back to @<github_org>."
  }

  # Negative: must not render the literal sentinel or an empty @-owner.
  assert {
    condition     = !strcontains(local_file.codeowners.content, "@codeowners_owner")
    error_message = "CODEOWNERS must not contain the literal variable name."
  }

  assert {
    condition     = !strcontains(local_file.codeowners.content, "* @\n")
    error_message = "CODEOWNERS default rule must not have an empty owner."
  }
}

run "codeowners_honors_explicit_team" {
  command = apply

  variables {
    codeowners_owner = "acme-co/platform-engineers"
  }

  assert {
    condition     = strcontains(local_file.codeowners.content, "@acme-co/platform-engineers")
    error_message = "Explicit codeowners_owner must appear verbatim with a leading @."
  }

  assert {
    condition     = !strcontains(local_file.codeowners.content, "* @acme-co\n")
    error_message = "Explicit team form must not also render the bare org fallback."
  }
}

run "readme_interpolates_display_name_and_repo" {
  command = apply

  assert {
    condition     = strcontains(local_file.readme.content, "# Acme Platform")
    error_message = "README must carry fleet_display_name as its H1."
  }

  assert {
    condition     = strcontains(local_file.readme.content, "https://github.com/acme-co/platform-fleet")
    error_message = "README must link to https://github.com/<github_org>/<github_repo>."
  }
}

run "marker_carries_template_commit_and_hashes" {
  command = apply

  assert {
    condition     = yamldecode(local_file.marker.content).template_commit == "deadbeefdeadbeefdeadbeefdeadbeefdeadbeef"
    error_message = ".fleet-initialized must record var.template_commit."
  }

  assert {
    condition     = yamldecode(local_file.marker.content).fleet_name == "acme"
    error_message = ".fleet-initialized must record var.fleet_name."
  }

  assert {
    condition = alltrue([
      for k in ["fleet_yaml", "codeowners", "readme"] :
      can(yamldecode(local_file.marker.content).rendered_files_sha1[k])
    ])
    error_message = ".fleet-initialized must expose rendered_files_sha1 for all three artefacts."
  }
}

# ---- validation rejections --------------------------------------------------
#
# One run block per variable whose validation rule we want to exercise.
# Each block overrides the single field under test with an invalid value
# and lists that var in expect_failures. Terraform treats the run as
# passing iff the declared failure fires.
#
# These runs use `command = plan` rather than `command = apply` because
# `validation {}` failures fire during plan: `apply` requires plan to
# succeed first, and an "expected" plan failure still blocks any
# subsequent apply — which the test runner then reports as a failure.
# `command = plan` is the correct idiom for `expect_failures` on an
# input validation.

run "reject_fleet_name_uppercase" {
  command = plan
  variables {
    fleet_name = "Acme"
  }
  expect_failures = [var.fleet_name]
}

run "reject_fleet_name_leading_digit" {
  command = plan
  variables {
    fleet_name = "1acme"
  }
  expect_failures = [var.fleet_name]
}

run "reject_fleet_name_too_long" {
  command = plan
  variables {
    fleet_name = "abcdefghijklm" # 13 chars
  }
  expect_failures = [var.fleet_name]
}

run "reject_fleet_display_name_empty" {
  command = plan
  variables {
    fleet_display_name = ""
  }
  expect_failures = [var.fleet_display_name]
}

run "reject_tenant_id_non_guid" {
  command = plan
  variables {
    tenant_id = "not-a-guid"
  }
  expect_failures = [var.tenant_id]
}

run "reject_sub_shared_non_guid" {
  command = plan
  variables {
    sub_shared = "xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx"
  }
  expect_failures = [var.sub_shared]
}

run "reject_github_org_leading_hyphen" {
  command = plan
  variables {
    github_org = "-acme"
  }
  expect_failures = [var.github_org]
}

run "reject_github_org_double_hyphen" {
  command = plan
  variables {
    github_org = "acme--co"
  }
  expect_failures = [var.github_org]
}

run "reject_github_repo_space" {
  command = plan
  variables {
    github_repo = "platform fleet"
  }
  expect_failures = [var.github_repo]
}

run "reject_team_template_repo_space" {
  command = plan
  variables {
    team_template_repo = "team repo template"
  }
  expect_failures = [var.team_template_repo]
}

run "reject_primary_region_uppercase" {
  command = plan
  variables {
    primary_region = "EastUS"
  }
  expect_failures = [var.primary_region]
}

run "reject_dns_fleet_root_uppercase" {
  command = plan
  variables {
    dns_fleet_root = "INT.acme.example"
  }
  expect_failures = [var.dns_fleet_root]
}

run "reject_dns_fleet_root_single_label" {
  command = plan
  variables {
    dns_fleet_root = "acme"
  }
  expect_failures = [var.dns_fleet_root]
}

run "reject_codeowners_owner_leading_slash" {
  command = plan
  variables {
    codeowners_owner = "/acme"
  }
  expect_failures = [var.codeowners_owner]
}

# ---- networking (PLAN §3.1 / §3.4) ------------------------------------------

run "render_networking_shape" {
  command = apply

  # Each non-mgmt env gets its own hub entry, keyed by env name.
  assert {
    condition = alltrue([
      yamldecode(local_file.fleet_yaml.content).networking.hubs.nonprod.regions.eastus.resource_id == "/subscriptions/66666666-6666-6666-6666-666666666666/resourceGroups/rg-hub/providers/Microsoft.Network/virtualNetworks/vnet-hub-nonprod-eastus",
      yamldecode(local_file.fleet_yaml.content).networking.hubs.prod.regions.eastus.resource_id == "/subscriptions/66666666-6666-6666-6666-666666666666/resourceGroups/rg-hub/providers/Microsoft.Network/virtualNetworks/vnet-hub-prod-eastus",
    ])
    error_message = "networking.hubs.<env>.regions.<primary_region>.resource_id must round-trip var.environments[<env>].hub_resource_id for every non-mgmt env."
  }

  # mgmt must NOT have its own hub entry — it peers to prod's hub via
  # mgmt_environment_for_vnet_peering.
  assert {
    condition     = !can(yamldecode(local_file.fleet_yaml.content).networking.hubs.mgmt)
    error_message = "networking.hubs.mgmt must NOT be rendered; mgmt peers via mgmt_environment_for_vnet_peering."
  }

  # Legacy flat `networking.hub` scalar must be gone.
  assert {
    condition     = !can(yamldecode(local_file.fleet_yaml.content).networking.hub.resource_id)
    error_message = "Legacy `networking.hub.resource_id` scalar must NOT be rendered (replaced by nested hubs.<env>.regions.<region> in PLAN §3.1)."
  }

  assert {
    condition = alltrue([
      yamldecode(local_file.fleet_yaml.content).networking.private_dns_zones.blob == "/subscriptions/66666666-6666-6666-6666-666666666666/resourceGroups/rg-hub-dns/providers/Microsoft.Network/privateDnsZones/privatelink.blob.core.windows.net",
      yamldecode(local_file.fleet_yaml.content).networking.private_dns_zones.vaultcore == "/subscriptions/66666666-6666-6666-6666-666666666666/resourceGroups/rg-hub-dns/providers/Microsoft.Network/privateDnsZones/privatelink.vaultcore.azure.net",
      yamldecode(local_file.fleet_yaml.content).networking.private_dns_zones.azurecr == "/subscriptions/66666666-6666-6666-6666-666666666666/resourceGroups/rg-hub-dns/providers/Microsoft.Network/privateDnsZones/privatelink.azurecr.io",
      yamldecode(local_file.fleet_yaml.content).networking.private_dns_zones.grafana == "/subscriptions/66666666-6666-6666-6666-666666666666/resourceGroups/rg-hub-dns/providers/Microsoft.Network/privateDnsZones/privatelink.grafana.azure.com",
    ])
    error_message = "networking.private_dns_zones.{blob,vaultcore,azurecr,grafana} must round-trip the four BYO zone id vars."
  }

  # Env VNets: address_space rendered as a LIST (per PLAN §3.1 example).
  # mgmt is a regular env-region entry under networking.envs (uniform
  # shape); the old `networking.vnets.mgmt` block is gone.
  assert {
    condition = alltrue([
      yamldecode(local_file.fleet_yaml.content).networking.envs.mgmt.regions.eastus.address_space == ["10.50.0.0/20"],
      yamldecode(local_file.fleet_yaml.content).networking.envs.nonprod.regions.eastus.address_space == ["10.70.0.0/20"],
      yamldecode(local_file.fleet_yaml.content).networking.envs.prod.regions.eastus.address_space == ["10.80.0.0/20"],
    ])
    error_message = "networking.envs.<env>.regions.<primary_region>.address_space must round-trip var.environments[<env>].address_space as a single-element LIST (PLAN §3.1)."
  }

  # mgmt env-region declares its peering target env.
  assert {
    condition     = yamldecode(local_file.fleet_yaml.content).networking.envs.mgmt.regions.eastus.mgmt_environment_for_vnet_peering == "prod"
    error_message = "networking.envs.mgmt.regions.<primary_region>.mgmt_environment_for_vnet_peering must be rendered from var.environments.mgmt.mgmt_peering_target_env (default `prod`)."
  }

  # Non-mgmt env-regions must NOT carry mgmt_environment_for_vnet_peering.
  assert {
    condition = alltrue([
      !can(yamldecode(local_file.fleet_yaml.content).networking.envs.nonprod.regions.eastus.mgmt_environment_for_vnet_peering),
      !can(yamldecode(local_file.fleet_yaml.content).networking.envs.prod.regions.eastus.mgmt_environment_for_vnet_peering),
    ])
    error_message = "mgmt_environment_for_vnet_peering must only appear on mgmt env-regions."
  }

  # create_reverse_peering is not emitted; bootstrap/environment defaults it.
  assert {
    condition = alltrue([
      !can(yamldecode(local_file.fleet_yaml.content).networking.envs.mgmt.regions.eastus.create_reverse_peering),
      !can(yamldecode(local_file.fleet_yaml.content).networking.envs.nonprod.regions.eastus.create_reverse_peering),
      !can(yamldecode(local_file.fleet_yaml.content).networking.envs.prod.regions.eastus.create_reverse_peering),
    ])
    error_message = "create_reverse_peering must be omitted from the template (default true applied downstream)."
  }

  # egress_next_hop_ip is emitted as null on every env-region so that
  # `yamldecode(...).networking.envs.<env>.regions.<region>` exposes the
  # key to fleet-identity + config-loader. Adopters overwrite after init.
  assert {
    condition = alltrue([
      yamldecode(local_file.fleet_yaml.content).networking.envs.mgmt.regions.eastus.egress_next_hop_ip == null,
      yamldecode(local_file.fleet_yaml.content).networking.envs.nonprod.regions.eastus.egress_next_hop_ip == null,
      yamldecode(local_file.fleet_yaml.content).networking.envs.prod.regions.eastus.egress_next_hop_ip == null,
    ])
    error_message = "networking.envs.<env>.regions.<region>.egress_next_hop_ip must be emitted as null on every env-region (PLAN §3.4; adopters fill it in post-init)."
  }

  # Legacy fleet-plane mgmt VNet block is gone.
  assert {
    condition     = !can(yamldecode(local_file.fleet_yaml.content).networking.vnets)
    error_message = "Legacy `networking.vnets.mgmt` block must NOT be rendered (collapsed into networking.envs.mgmt in PLAN §3.4)."
  }

  # Legacy BYO subnet fields must NOT be present.
  assert {
    condition = alltrue([
      !can(yamldecode(local_file.fleet_yaml.content).networking.tfstate),
      !can(yamldecode(local_file.fleet_yaml.content).networking.runner),
      !can(yamldecode(local_file.fleet_yaml.content).networking.fleet_kv),
    ])
    error_message = "Legacy BYO subnet fields must be absent post Phase-B schema flip (PLAN §3.4)."
  }
}

# ---- networking validation rejections --------------------------------------

run "reject_pdz_blob_wrong_zone_name" {
  command = plan
  variables {
    networking_pdz_blob = "/subscriptions/66666666-6666-6666-6666-666666666666/resourceGroups/rg-hub-dns/providers/Microsoft.Network/privateDnsZones/privatelink.queue.core.windows.net"
  }
  expect_failures = [var.networking_pdz_blob]
}

run "reject_pdz_vaultcore_wrong_zone_name" {
  command = plan
  variables {
    networking_pdz_vaultcore = "/subscriptions/66666666-6666-6666-6666-666666666666/resourceGroups/rg-hub-dns/providers/Microsoft.Network/privateDnsZones/privatelink.blob.core.windows.net"
  }
  expect_failures = [var.networking_pdz_vaultcore]
}

# ---- environments map validation rejections --------------------------------

run "reject_environments_missing_mgmt" {
  command = plan
  variables {
    environments = {
      nonprod = {
        subscription_id = "44444444-4444-4444-4444-444444444444"
        address_space   = "10.70.0.0/20"
        hub_resource_id = "/subscriptions/66666666-6666-6666-6666-666666666666/resourceGroups/rg-hub/providers/Microsoft.Network/virtualNetworks/vnet-hub-nonprod-eastus"
      }
      prod = {
        subscription_id = "55555555-5555-5555-5555-555555555555"
        address_space   = "10.80.0.0/20"
        hub_resource_id = "/subscriptions/66666666-6666-6666-6666-666666666666/resourceGroups/rg-hub/providers/Microsoft.Network/virtualNetworks/vnet-hub-prod-eastus"
      }
    }
  }
  expect_failures = [var.environments]
}

run "reject_environments_invalid_env_name" {
  command = plan
  variables {
    environments = {
      mgmt = {
        subscription_id = "33333333-3333-3333-3333-333333333333"
        address_space   = "10.50.0.0/20"
      }
      "Prod" = {
        subscription_id = "55555555-5555-5555-5555-555555555555"
        address_space   = "10.80.0.0/20"
        hub_resource_id = "/subscriptions/66666666-6666-6666-6666-666666666666/resourceGroups/rg-hub/providers/Microsoft.Network/virtualNetworks/vnet-hub-prod-eastus"
      }
    }
  }
  expect_failures = [var.environments]
}

run "reject_environments_subscription_id_not_guid" {
  command = plan
  variables {
    environments = {
      mgmt = {
        subscription_id = "33333333-3333-3333-3333-333333333333"
        address_space   = "10.50.0.0/20"
      }
      prod = {
        subscription_id = "not-a-guid"
        address_space   = "10.80.0.0/20"
        hub_resource_id = "/subscriptions/66666666-6666-6666-6666-666666666666/resourceGroups/rg-hub/providers/Microsoft.Network/virtualNetworks/vnet-hub-prod-eastus"
      }
    }
  }
  expect_failures = [var.environments]
}

run "reject_environments_address_space_not_cidr" {
  command = plan
  variables {
    environments = {
      mgmt = {
        subscription_id = "33333333-3333-3333-3333-333333333333"
        address_space   = "not-a-cidr"
      }
      prod = {
        subscription_id = "55555555-5555-5555-5555-555555555555"
        address_space   = "10.80.0.0/20"
        hub_resource_id = "/subscriptions/66666666-6666-6666-6666-666666666666/resourceGroups/rg-hub/providers/Microsoft.Network/virtualNetworks/vnet-hub-prod-eastus"
      }
    }
  }
  expect_failures = [var.environments]
}

run "reject_environments_address_space_too_narrow" {
  command = plan
  variables {
    environments = {
      mgmt = {
        subscription_id = "33333333-3333-3333-3333-333333333333"
        address_space   = "10.50.0.0/24"
      }
      prod = {
        subscription_id = "55555555-5555-5555-5555-555555555555"
        address_space   = "10.80.0.0/20"
        hub_resource_id = "/subscriptions/66666666-6666-6666-6666-666666666666/resourceGroups/rg-hub/providers/Microsoft.Network/virtualNetworks/vnet-hub-prod-eastus"
      }
    }
  }
  expect_failures = [var.environments]
}

run "reject_environments_address_space_not_rfc1918" {
  command = plan
  variables {
    environments = {
      mgmt = {
        subscription_id = "33333333-3333-3333-3333-333333333333"
        address_space   = "8.8.0.0/20"
      }
      prod = {
        subscription_id = "55555555-5555-5555-5555-555555555555"
        address_space   = "10.80.0.0/20"
        hub_resource_id = "/subscriptions/66666666-6666-6666-6666-666666666666/resourceGroups/rg-hub/providers/Microsoft.Network/virtualNetworks/vnet-hub-prod-eastus"
      }
    }
  }
  expect_failures = [var.environments]
}

run "reject_environments_address_space_host_bits_set" {
  command = plan
  variables {
    environments = {
      mgmt = {
        subscription_id = "33333333-3333-3333-3333-333333333333"
        address_space   = "10.50.0.1/20"
      }
      prod = {
        subscription_id = "55555555-5555-5555-5555-555555555555"
        address_space   = "10.80.0.0/20"
        hub_resource_id = "/subscriptions/66666666-6666-6666-6666-666666666666/resourceGroups/rg-hub/providers/Microsoft.Network/virtualNetworks/vnet-hub-prod-eastus"
      }
    }
  }
  expect_failures = [var.environments]
}

run "reject_environments_address_space_exact_overlap" {
  command = plan
  variables {
    environments = {
      mgmt = {
        subscription_id = "33333333-3333-3333-3333-333333333333"
        address_space   = "10.50.0.0/20"
      }
      prod = {
        subscription_id = "55555555-5555-5555-5555-555555555555"
        address_space   = "10.50.0.0/20" # exact match with mgmt
        hub_resource_id = "/subscriptions/66666666-6666-6666-6666-666666666666/resourceGroups/rg-hub/providers/Microsoft.Network/virtualNetworks/vnet-hub-prod-eastus"
      }
    }
  }
  expect_failures = [var.environments]
}

run "reject_environments_address_space_partial_overlap" {
  command = plan
  variables {
    environments = {
      mgmt = {
        subscription_id = "33333333-3333-3333-3333-333333333333"
        address_space   = "10.50.0.0/20"
      }
      prod = {
        subscription_id = "55555555-5555-5555-5555-555555555555"
        address_space   = "10.50.0.0/21" # /21 subset of mgmt's /20
        hub_resource_id = "/subscriptions/66666666-6666-6666-6666-666666666666/resourceGroups/rg-hub/providers/Microsoft.Network/virtualNetworks/vnet-hub-prod-eastus"
      }
    }
  }
  expect_failures = [var.environments]
}

run "reject_environments_mgmt_has_hub_resource_id" {
  command = plan
  variables {
    environments = {
      mgmt = {
        subscription_id = "33333333-3333-3333-3333-333333333333"
        address_space   = "10.50.0.0/20"
        hub_resource_id = "/subscriptions/66666666-6666-6666-6666-666666666666/resourceGroups/rg-hub/providers/Microsoft.Network/virtualNetworks/vnet-hub-mgmt"
      }
      prod = {
        subscription_id = "55555555-5555-5555-5555-555555555555"
        address_space   = "10.80.0.0/20"
        hub_resource_id = "/subscriptions/66666666-6666-6666-6666-666666666666/resourceGroups/rg-hub/providers/Microsoft.Network/virtualNetworks/vnet-hub-prod-eastus"
      }
    }
  }
  expect_failures = [var.environments]
}

run "reject_environments_nonmgmt_missing_hub_resource_id" {
  command = plan
  variables {
    environments = {
      mgmt = {
        subscription_id = "33333333-3333-3333-3333-333333333333"
        address_space   = "10.50.0.0/20"
      }
      prod = {
        subscription_id = "55555555-5555-5555-5555-555555555555"
        address_space   = "10.80.0.0/20"
        # hub_resource_id missing
      }
    }
  }
  expect_failures = [var.environments]
}

run "reject_environments_hub_not_full_arm_id" {
  command = plan
  variables {
    environments = {
      mgmt = {
        subscription_id = "33333333-3333-3333-3333-333333333333"
        address_space   = "10.50.0.0/20"
      }
      prod = {
        subscription_id = "55555555-5555-5555-5555-555555555555"
        address_space   = "10.80.0.0/20"
        hub_resource_id = "vnet-hub-prod-eastus"
      }
    }
  }
  expect_failures = [var.environments]
}

run "reject_environments_mgmt_peering_target_missing_env" {
  command = plan
  variables {
    environments = {
      mgmt = {
        subscription_id         = "33333333-3333-3333-3333-333333333333"
        address_space           = "10.50.0.0/20"
        mgmt_peering_target_env = "staging" # no such env in the map
      }
      prod = {
        subscription_id = "55555555-5555-5555-5555-555555555555"
        address_space   = "10.80.0.0/20"
        hub_resource_id = "/subscriptions/66666666-6666-6666-6666-666666666666/resourceGroups/rg-hub/providers/Microsoft.Network/virtualNetworks/vnet-hub-prod-eastus"
      }
    }
  }
  expect_failures = [var.environments]
}

run "reject_environments_mgmt_peering_target_is_mgmt" {
  command = plan
  variables {
    environments = {
      mgmt = {
        subscription_id         = "33333333-3333-3333-3333-333333333333"
        address_space           = "10.50.0.0/20"
        mgmt_peering_target_env = "mgmt"
      }
      prod = {
        subscription_id = "55555555-5555-5555-5555-555555555555"
        address_space   = "10.80.0.0/20"
        hub_resource_id = "/subscriptions/66666666-6666-6666-6666-666666666666/resourceGroups/rg-hub/providers/Microsoft.Network/virtualNetworks/vnet-hub-prod-eastus"
      }
    }
  }
  expect_failures = [var.environments]
}
