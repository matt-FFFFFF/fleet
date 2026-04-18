# stages/0-fleet variables.
#
# Fleet identity is sourced from clusters/_fleet.yaml (see main.tf locals).
# Stage 0 is currently parameterless in the committed scaffold — everything
# it needs today lives in that file.
#
# PLAN §4 Stage 0 additionally specifies GitHub App inputs
# (`fleet_meta_app_id`, `fleet_meta_app_pem`,
#  `fleet_meta_app_webhook_secret`, `fleet_meta_app_client_id`,
#  `stage0_publisher_app_id`, `stage0_publisher_app_pem`,
#  `stage0_publisher_app_webhook_secret`,
#  `stage0_publisher_app_client_id`)
# to be consumed from a repo-root `.gh-apps.auto.tfvars` overlay written
# by the (not-yet-implemented) `init-gh-apps.sh` helper (PLAN §16.4;
# implementation-status callout in §16 flags §16.4 as Phase 1 spec-
# only). Those `variable` blocks — and the KV-seed / repo-variable-
# publish resources that consume them — land together with §16.4's
# helper; they intentionally do not ship in this scaffold.
