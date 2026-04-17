# main.state.tf
#
# Per-env state container under the shared tfstate-fleet SA. Seeded here so
# downstream Stage 1 / Stage 2 cluster applies have a backend.
#
# SA itself is in sub-fleet-shared (`var.fleet.state.subscription_id`), while
# this stage runs with azapi pointed at the env subscription. We override
# parent_id by constructing the full SA resource path explicitly.

locals {
  state_sa_id = join("/", [
    "/subscriptions", var.fleet.state.subscription_id,
    "resourceGroups", var.fleet.state.resource_group,
    "providers/Microsoft.Storage/storageAccounts", var.fleet.state.storage_account,
  ])
  state_blob_svc_id    = "${local.state_sa_id}/blobServices/default"
  state_container_name = "tfstate-${var.env}"
}

resource "azapi_resource" "state_container_env" {
  type      = "Microsoft.Storage/storageAccounts/blobServices/containers@2023-05-01"
  name      = local.state_container_name
  parent_id = local.state_blob_svc_id

  body = {
    properties = { publicAccess = "None" }
  }
}
