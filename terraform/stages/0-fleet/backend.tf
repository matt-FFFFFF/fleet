# stages/0-fleet/backend.tf
#
# Backend config is supplied during `terraform init` via -backend-config
# flags, using values from bootstrap/fleet outputs and/or the
# fleet-stage0 environment:
#
#   -backend-config="resource_group_name=<state_resource_group>"
#   -backend-config="storage_account_name=<state_storage_account>"
#   -backend-config="container_name=tfstate-fleet"
#   -backend-config="key=stage0/fleet.tfstate"
#   -backend-config="use_oidc=true"
#   -backend-config="use_azuread_auth=true"
#
# Today this is invoked manually (or from ad-hoc CI); once the planned
# `tf-apply.yaml` workflow lands it will supply the same flags from
# bootstrap/fleet outputs. See PLAN §16 implementation status.
#
# The empty backend block in providers.tf is the anchor; this file is a
# placeholder for future partial-config hints and is intentionally empty
# of HCL.
