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
  sub_mgmt           = "33333333-3333-3333-3333-333333333333"
  sub_nonprod        = "44444444-4444-4444-4444-444444444444"
  sub_prod           = "55555555-5555-5555-5555-555555555555"
  dns_fleet_root     = "int.acme.example"
  template_commit    = "deadbeefdeadbeefdeadbeefdeadbeefdeadbeef"
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

  assert {
    condition     = yamldecode(local_file.fleet_yaml.content).fleet.primary_region == "eastus"
    error_message = "Rendered _fleet.yaml must carry fleet.primary_region = var.primary_region."
  }

  assert {
    condition     = yamldecode(local_file.fleet_yaml.content).dns.fleet_root == "int.acme.example"
    error_message = "Rendered _fleet.yaml must carry dns.fleet_root = var.dns_fleet_root."
  }

  # Each env subscription id lands in the right slot.
  assert {
    condition = alltrue([
      yamldecode(local_file.fleet_yaml.content).environments.mgmt.subscription_id == "33333333-3333-3333-3333-333333333333",
      yamldecode(local_file.fleet_yaml.content).environments.nonprod.subscription_id == "44444444-4444-4444-4444-444444444444",
      yamldecode(local_file.fleet_yaml.content).environments.prod.subscription_id == "55555555-5555-5555-5555-555555555555",
    ])
    error_message = "environments.<env>.subscription_id must map 1:1 to var.sub_{mgmt,nonprod,prod}."
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

run "reject_sub_mgmt_non_guid" {
  command = plan
  variables {
    sub_mgmt = ""
  }
  expect_failures = [var.sub_mgmt]
}

run "reject_sub_nonprod_non_guid" {
  command = plan
  variables {
    sub_nonprod = "foo"
  }
  expect_failures = [var.sub_nonprod]
}

run "reject_sub_prod_non_guid" {
  command = plan
  variables {
    sub_prod = "foo"
  }
  expect_failures = [var.sub_prod]
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
