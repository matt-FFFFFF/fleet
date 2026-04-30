# stages/1-cluster/main.kv.tf
#
# Per-cluster Key Vault (PLAN §4 Stage 1). Named `kv-<cluster.name>`
# (truncated to 24 chars) in `<cluster.resource_group>` — both derived
# by `config-loader/load.sh` into `derived.keyvault_name` and
# `derived.keyvault_resource_group` (override paths live on
# `platform.keyvault.{name,resource_group}`).
#
# Holds cluster-local secrets (TLS wildcards, team app secrets, etc.).
# Role assignments on this KV (ESO UAMI → KV Secrets User) live in
# main.rbac.tf; the module itself stays scope-agnostic so an operator
# could reuse it if a second fleet-local KV is ever introduced.
#
# On the **management cluster only**, this KV doubles as the
# fleet-shared mgmt cluster KV: it receives the Argo + Kargo OIDC RP
# `client_secret` values written by `bootstrap/fleet` on its
# second-pass apply (after this stage publishes `MGMT_CLUSTER_KV_ID`),
# and the `argocd-github-app-pem` / `kargo-github-app-pem` seeded
# out-of-band by ESO/operator. Stage 1 itself does NOT author any of
# those secret values — see PLAN §4 Stage -1 for the AAD-app design.

module "cluster_kv" {
  source = "../../modules/cluster-kv"

  name      = local.derived.keyvault_name
  location  = local.cluster.region
  parent_id = "/subscriptions/${local.cluster.subscription_id}/resourceGroups/${local.derived.keyvault_resource_group}"
  tenant_id = local.fleet.tenant_id

  tags = {
    fleet       = local.fleet.name
    environment = local.cluster.env
    region      = local.cluster.region
    cluster     = local.cluster.name
    role        = try(local.cluster.role, "workload")
    stage       = "1-cluster"
  }
}
