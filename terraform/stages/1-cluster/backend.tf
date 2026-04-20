# stages/1-cluster/backend.tf
#
# Partial backend config — values arrive via `terraform init -backend-config`
# from the (planned) `tf-apply.yaml` workflow (PLAN §10). Current manual
# invocation template:
#
#   terraform init \
#     -backend-config="resource_group_name=<state RG from bootstrap/fleet>" \
#     -backend-config="storage_account_name=<state SA from bootstrap/fleet>" \
#     -backend-config="subscription_id=<_fleet.yaml state.subscription_id>" \
#     -backend-config="container_name=<env state container from bootstrap/environment>" \
#     -backend-config="key=stage1/<env>/<region>/<cluster_name>.tfstate" \
#     -backend-config="use_oidc=true" \
#     -backend-config="use_azuread_auth=true"
#
# The state container is per-env (published by `bootstrap/environment` as
# `env_state_container`), not the fleet-wide `tfstate-fleet`; this keeps
# env teardown atomic and stops a prod apply from touching nonprod state.
#
# Backend block anchor lives in providers.tf; this file is intentionally
# comment-only.
