# main.identities.tf
#
# Phase 1 scope for this file post-vendor-refactor:
#   * the fleet shared resource group (ACR, fleet KV, and fleet-stage0 /
#     fleet-meta UAMIs all live here),
#   * Azure role-GUID locals (used both here and in main.github.tf's
#     `identity_role_assignments` map),
#   * Microsoft Graph app-role assignment on `fleet-stage0` (the module
#     cannot assign Entra roles).
#
# The fleet-stage0 + fleet-meta UAMIs, their federated credentials, and
# their Azure RBAC assignments are created by `module.fleet_repo` (see
# main.github.tf). The Graph app-role assignment here references that
# module's environment outputs for the principal id.

# --- Fleet shared resource group (for ACR / fleet KV / shared state) ---------

resource "azapi_resource" "rg_fleet_shared" {
  type      = "Microsoft.Resources/resourceGroups@2024-03-01"
  name      = local.derived.acr_resource_group
  parent_id = "/subscriptions/${local.derived.acr_subscription_id}"
  location  = local.derived.acr_location

  body = {}
}

# --- Azure RBAC role-definition GUIDs ---------------------------------------
#
# Built-in role GUIDs used by this stage + the env bootstrap stage.
#
# User Access Administrator (`18d7d88d-d35e-4fb5-a5c3-7773c20a72d9`) is not
# used in this stage; reintroduce when Stage 0 delegates RBAC assignments to
# the fleet-meta identity.

locals {
  role_contributor    = "b24988ac-6180-42a0-ab88-20f7382dd24c"
  role_blob_data_ctrb = "ba92f5b4-2d11-453d-a403-e96b0029c9fe"
}

# --- Microsoft Graph app-role assignments -----------------------------------
#
# `fleet-stage0` holds `Application.ReadWrite.OwnedBy` on the Microsoft
# Graph SP: scoped CRUD on any AAD application where the assignee is
# listed as an owner. In practice this UAMI ever owns exactly two apps
# — the fleet-wide Argo and Kargo OIDC clients created by Stage 0 (see
# `terraform/stages/0-fleet/main.aad.tf`). Per PLAN §1 hub-and-spoke
# both apps are mgmt-only singletons, so the practical blast radius of
# this grant is "those two apps for the lifetime of the fleet."
#
# Graph does not offer a finer-grained "this specific app" automated
# role; `Application.ReadWrite.OwnedBy` is the narrowest available
# without moving rotation off-CI to a delegated user flow.
#
# This grant is created here under tenant-admin (the human running
# `bootstrap/fleet` for the first time). It requires Entra tenant-admin
# consent on first apply; same precondition as before. See
# `docs/adoption.md §5.1`.
#
# `fleet-meta` does NOT hold `AppRoleAssignment.ReadWrite.All` or any
# other Graph permission. Under PLAN §1 hub-and-spoke the only UAMI
# that needs `Application.ReadWrite.OwnedBy` besides `fleet-stage0`
# is `uami-fleet-mgmt` (for Stage 1 mgmt-cluster Kargo password
# rotation; future mgmt-side Argo / Kargo FICs land here too). That
# UAMI is created by `bootstrap/environment` env=mgmt, which runs
# **after** this stage; granting it from Terraform would require
# either a two-pass bootstrap or a long-lived `AppRoleAssignment.
# ReadWrite.All` on `fleet-meta`. Neither is justified for a single
# one-off grant — instead, the operator issues it manually via `az`
# once after env=mgmt bootstraps. See `docs/adoption.md §5.1`.

# Microsoft Graph service principal in this tenant. Required as the
# `resource_object_id` for the `azuread_app_role_assignment` below.
data "azuread_service_principal" "msgraph" {
  client_id = "00000003-0000-0000-c000-000000000000"
}

locals {
  # Graph app-role id (stable across tenants).
  msgraph_role_application_readwrite_ownedby = "18a4783c-866b-4cc7-a460-3d5e5662c884"
}

resource "azuread_app_role_assignment" "stage0_app_rw_owned_by" {
  app_role_id         = local.msgraph_role_application_readwrite_ownedby
  principal_object_id = module.fleet_repo.environments["stage0"].identity.principal_id
  resource_object_id  = data.azuread_service_principal.msgraph.object_id
}
