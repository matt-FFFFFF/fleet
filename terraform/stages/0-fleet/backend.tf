# stages/0-fleet/backend.tf
#
# Backend config is supplied at init time via -backend-config flags from
# tf-apply.yaml (values from bootstrap/fleet outputs / fleet-stage0 env):
#
#   -backend-config="resource_group_name=<state_resource_group>"
#   -backend-config="storage_account_name=<state_storage_account>"
#   -backend-config="container_name=tfstate-fleet"
#   -backend-config="key=stage0/fleet.tfstate"
#   -backend-config="use_oidc=true"
#   -backend-config="use_azuread_auth=true"
#
# The empty backend block in providers.tf is the anchor; this file is a
# placeholder for future partial-config hints and is intentionally empty
# of HCL.
