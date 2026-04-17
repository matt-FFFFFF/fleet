# stages/0-fleet
#
# Fleet-global, applied once and thereafter on additions only (new cluster
# in the inventory → redirect URI list on the Argo/Kargo AAD apps is
# re-computed; new fleet-wide secret → added here). See PLAN §4 Stage 0.
#
# Creates:
#   1. ACR (single fleet registry; also hosts Helm OCI charts)
#   2. Fleet Key Vault (ONLY fleet-wide secrets; per-cluster KVs are Stage 1)
#   3. Argo AAD application (OIDC client for every cluster's ArgoCD)
#      - web.redirect_uris computed from the cluster inventory
#      - azuread_application_password rotated every 60d, written to fleet KV
#   4. Kargo AAD application (OIDC client for the mgmt cluster's Kargo)
#      - web.redirect_uris scoped to the mgmt cluster(s) only
#      - NO password created here (lives in the mgmt cluster's Stage 1 KV)
#   5. uami-kargo-mgmt UAMI (fleet-wide singleton) + AcrPull on the ACR
#
# Fleet identity is read from clusters/_fleet.yaml via yamldecode; there is
# no var.fleet. The cluster inventory (for redirect URI derivation) is
# scanned from clusters/*/*/*/cluster.yaml at plan time.
#
# Files:
#   main.tf              locals + cluster inventory scan (this file)
#   main.acr.tf          ACR
#   main.kv.tf           fleet KV + RBAC assignments
#   main.aad.tf          Argo + Kargo AAD apps; Argo RP secret rotation
#   main.identities.tf   uami-kargo-mgmt + AcrPull
#   outputs.tf           outputs (published as repo variables by tf-apply.yaml)

locals {
  fleet_yaml_path = "${path.module}/../../../clusters/_fleet.yaml"
  fleet_doc       = yamldecode(file(local.fleet_yaml_path))

  fleet = local.fleet_doc.fleet
  aad   = local.fleet_doc.aad
  dns   = local.fleet_doc.dns

  # Derived names — must match docs/naming.md and the bootstrap HCL locals.
  derived = {
    acr_name = coalesce(
      try(local.fleet_doc.acr.name_override, ""),
      "acr${local.fleet.name}shared",
    )
    acr_resource_group  = local.fleet_doc.acr.resource_group
    acr_subscription_id = local.fleet_doc.acr.subscription_id
    acr_location        = local.fleet_doc.acr.location
    acr_sku             = try(local.fleet_doc.acr.sku, "Premium")

    fleet_kv_name = coalesce(
      try(local.fleet_doc.keyvault.name_override, ""),
      substr("kv-${local.fleet.name}-fleet", 0, 24),
    )
    fleet_kv_resource_group = local.fleet_doc.keyvault.resource_group
    fleet_kv_location       = try(local.fleet_doc.keyvault.location, local.fleet.primary_region)

    # Fleet-shared RG is created by bootstrap/fleet; Stage 0 references it
    # by name, not resource id, so its full id is reconstructed here.
    fleet_shared_rg_id = "/subscriptions/${local.fleet_doc.acr.subscription_id}/resourceGroups/${local.fleet_doc.acr.resource_group}"
  }

  # --- Cluster inventory scan ------------------------------------------------
  #
  # Every cluster file lives at clusters/<env>/<region>/<name>/cluster.yaml.
  # fileset() matches only that depth; clusters/_template/cluster.yaml (two
  # segments) is excluded automatically.
  cluster_files = fileset("${path.module}/../../../clusters", "*/*/*/cluster.yaml")

  clusters = [
    for f in local.cluster_files : {
      env    = split("/", f)[0]
      region = split("/", f)[1]
      name   = split("/", f)[2]
      role   = try(yamldecode(file("${path.module}/../../../clusters/${f}")).cluster.role, "workload")
    }
  ]

  mgmt_clusters = [for c in local.clusters : c if c.role == "management"]

  # Redirect URI formula (derived from the directory path per PLAN §3.2 /
  # §4 Stage 0). Adding a cluster → Stage 0 re-apply updates these lists
  # atomically on the AAD apps.
  argo_redirect_uris = [
    for c in local.clusters :
    "https://argocd.${c.name}.${c.region}.${c.env}.${local.dns.fleet_root}/auth/callback"
  ]
  kargo_redirect_uris = [
    for c in local.mgmt_clusters :
    "https://kargo.${c.name}.${c.region}.${c.env}.${local.dns.fleet_root}/auth/callback"
  ]
}
