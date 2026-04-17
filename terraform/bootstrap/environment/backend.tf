# Backend config is supplied at init-time:
#   terraform init \
#     -backend-config=resource_group_name=rg-fleet-tfstate \
#     -backend-config=storage_account_name=<fleet.state.storage_account> \
#     -backend-config=container_name=tfstate-fleet \
#     -backend-config=key=bootstrap/environment/<env>.tfstate \
#     -backend-config=use_oidc=true \
#     -backend-config=use_azuread_auth=true \
#     -backend-config=subscription_id=<fleet.state.subscription_id>
#
# See .github/workflows/env-bootstrap.yaml for the wiring.
