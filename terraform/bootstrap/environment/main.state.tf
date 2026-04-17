# main.state.tf
#
# Per-env state container under the shared tfstate-fleet SA. Seeded here so
# downstream Stage 1 / Stage 2 cluster applies have a backend.
#
# SA itself is in sub-fleet-shared (fleet.state.subscription_id), while this
# stage runs with azapi pointed at the env subscription. We override parent_id
# by constructing the full SA resource path explicitly.

locals {
  state_sa_id = join("/", [
    "/subscriptions", local.derived.state_subscription,
    "resourceGroups", local.derived.state_resource_group,
    "providers/Microsoft.Storage/storageAccounts", local.derived.state_storage_account,
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

  # Foundational resource for this stage — gate here so a misspelled or
  # missing var.env fails with an actionable message instead of the generic
  # "Invalid index" thrown by local.environment downstream.
  lifecycle {
    precondition {
      condition = contains(keys(local.fleet_doc.environments), var.env)
      error_message = format(
        "env %q is not declared in clusters/_fleet.yaml.environments; declared envs: %s",
        var.env,
        join(", ", keys(local.fleet_doc.environments)),
      )
    }
  }
}
