# stages/1-cluster/variables.tf
#
# Inputs arrive two ways:
#
#   1. `var.doc` — a single JSON blob produced by
#      `terraform/config-loader/load.sh <cluster-path>`, which deep-merges
#      clusters/_defaults.yaml << env/_defaults.yaml << region/_defaults.yaml
#      << cluster.yaml, then injects `.fleet` (from _fleet.yaml), the
#      derived identity fields (`.cluster.{name,env,region,subscription_id}`)
#      and the `.derived.*` block (DNS zone, KV name, ACR login server,
#      per-cluster subnet names + CIDRs, cluster-slot capacity, etc.).
#      Pod CIDR is NOT in this block — it is a fleet-wide constant
#      hard-coded in `modules/aks-cluster/main.tf` (see PLAN §3.4
#      Implementation status 2026-04-21). All structure is documented
#      in config-loader/load.sh's header comment.
#
#   2. Named variables below — the handful of pre-created Azure resource
#      ids this stack must reference but cannot author itself. These are
#      populated from repo-environment variables by the `tf-apply.yaml`
#      workflow (PLAN §10; not yet implemented — piping is documentation
#      today, wired when the workflow lands):
#
#        env_region_vnet_resource_id  ← <ENV>_<REGION>_VNET_RESOURCE_ID
#                                       (bootstrap/environment)
#        mgmt_region_vnet_resource_id ← fromJSON(MGMT_VNET_RESOURCE_IDS)[<mgmt-region>]
#                                       where <mgmt-region> is resolved
#                                       by config-loader/load.sh per the
#                                       same-region-else-first rule and
#                                       emitted as
#                                       `derived.networking.peer_mgmt_region`
#                                       (non-mgmt clusters) or the
#                                       cluster's own region (mgmt
#                                       clusters). `MGMT_VNET_RESOURCE_IDS`
#                                       is the JSON-encoded map
#                                       published on the `fleet-meta`
#                                       GitHub Environment by
#                                       `bootstrap/fleet`.
#        node_asg_resource_id         ← <ENV>_<REGION>_NODE_ASG_RESOURCE_ID
#                                       (bootstrap/environment)
#        route_table_resource_id      ← <ENV>_<REGION>_ROUTE_TABLE_RESOURCE_ID
#                                       (bootstrap/environment). Stage 1
#                                       sets `routeTableId` on BOTH the
#                                       api and nodes subnets from this
#                                       id so api-server VNet integration
#                                       and node egress route 0.0.0.0/0
#                                       through the same next-hop
#                                       (PLAN §3.4 UDR egress).
#
# Everything else — tenant ids, subscription ids, names, CIDRs — is
# authoritative in clusters/_fleet.yaml (rendered from init/) and flows
# through the loader. There is exactly **one** source for each fact
# (AGENTS.md rule 4).

variable "doc" {
  description = <<-EOT
    Merged cluster document from `terraform/config-loader/load.sh`. See
    that script's header for the canonical schema; stages/1-cluster only
    consumes a narrow subset (cluster, fleet, derived.networking, aks)
    and treats everything else (including `platform`, which is consumed
    by Stage 2) as opaque passthrough.
  EOT
  # Intentionally untyped — the loader contract + lifecycle.precondition
  # blocks in main.tf are the schema; forcing a HCL type here would make
  # the stack brittle to loader additions.
  type = any
}

variable "env_region_vnet_resource_id" {
  description = <<-EOT
    Full ARM id of the env-region VNet owned by `bootstrap/environment`
    (one per env-region). The `/28` api subnet and `/25` nodes subnet
    authored by this stack are children of this VNet; the cluster's
    private DNS zone is also linked to it. Published as the
    `<ENV>_<REGION>_VNET_RESOURCE_ID` repo-environment variable.
  EOT
  type        = string
  nullable    = false
}

variable "mgmt_region_vnet_resource_id" {
  description = <<-EOT
    Full ARM id of the mgmt env-region VNet for this cluster's peering
    region, owned by `bootstrap/environment` (the env=mgmt branch) on a
    VNet shell created by `bootstrap/fleet`. Linked to this cluster's
    private DNS zone so in-cluster hostnames resolve from the mgmt plane
    (Kargo, fleet-wide tooling, platform CI). Selected per-cluster by
    `tf-apply.yaml` via
    `fromJSON(vars.MGMT_VNET_RESOURCE_IDS)[<mgmt-region>]`, where
    `<mgmt-region>` is the `derived.networking.peer_mgmt_region` value
    emitted by the loader (same-region-else-first resolution against
    `networking.envs.mgmt.regions.*`). For mgmt clusters this equals
    `env_region_vnet_resource_id` — Stage 1 detects the collapse and
    deduplicates the DNS zone link set to avoid the API's
    duplicate-link error.
  EOT
  type        = string
  nullable    = false
}

variable "node_asg_resource_id" {
  description = <<-EOT
    Full ARM id of the shared `asg-nodes-<env>-<region>` Application
    Security Group owned by `bootstrap/environment`. Attached to every
    AKS cluster's node-pool NICs in this env-region via the AVM
    module's `agent_pools.*.network_profile.application_security_groups`
    input (PLAN §3.4). Published as `<ENV>_<REGION>_NODE_ASG_RESOURCE_ID`.
  EOT
  type        = string
  nullable    = false
}

variable "route_table_resource_id" {
  description = <<-EOT
    Full ARM id of the `rt-aks-<env>-<region>` route table owned by
    `bootstrap/environment`. Stage 1 associates it with BOTH the per-cluster
    `/28` api subnet (delegated to the AKS api-server VNet integration)
    and the `/25` nodes subnet so both surfaces route `0.0.0.0/0` through
    the hub-firewall next-hop declared in
    `networking.envs.<env>.regions.<region>.egress_next_hop_ip`
    (PLAN §3.4 UDR egress). The route table shell is authored
    unconditionally by `bootstrap/environment`; the `0.0.0.0/0` route
    entry exists only when `egress_next_hop_ip` is non-null, so Stage 1
    live-apply on a cluster requires the adopter to have filled in the
    next-hop IP for the cluster's region first. Published as
    `<ENV>_<REGION>_ROUTE_TABLE_RESOURCE_ID`.
  EOT
  type        = string
  nullable    = false
}

# --- Fleet-scope passthroughs (published by Stage 0) -----------------------
#
# These piggyback on the Stage 0 → repo-variable publishing path (PLAN §4
# Stage 0 Outputs). `tf-apply.yaml` wires each to a `TF_VAR_*` of the
# same snake-case name for every Stage 1 leg. No remote state, no
# plan-time data sources — everything arrives as a string.

variable "fleet_keyvault_id" {
  description = <<-EOT
    Full ARM id of the fleet-shared Key Vault (`kv-<fleet.name>-fleet`),
    owned by `bootstrap/fleet`. Stage 1 assigns `Key Vault Secrets User`
    on this KV to the cluster's ESO UAMI so fleet-wide secrets (GH App
    PEMs, etc.) flow through External Secrets Operator. Published as
    the `FLEET_KEYVAULT_ID` fleet-scope repo variable (Stage 0 output
    `fleet_keyvault_id`).
  EOT
  type        = string
  nullable    = false
}

variable "acr_resource_id" {
  description = <<-EOT
    Full ARM id of the fleet-shared ACR (`acr<fleet.name>shared`), owned
    by `bootstrap/fleet`. Stage 1 assigns `AcrPull` on this ACR to the
    cluster's AKS-managed kubelet identity (read from the AVM module's
    `kubelet_identity.object_id` output). Published as the
    `ACR_RESOURCE_ID` fleet-scope repo variable (Stage 0 output
    `acr_resource_id`).
  EOT
  type        = string
  nullable    = false
}

variable "kargo_mgmt_uami_principal_id" {
  description = <<-EOT
    Principal id of the fleet-wide singleton Kargo UAMI
    (`uami-kargo-mgmt`), owned by Stage 0. Stage 1 assigns `Azure
    Kubernetes Service RBAC Reader` on the **mgmt** cluster's AKS
    resource to this principalId so Kargo (mgmt-resident) can read
    Argo `Application` CRs — under PLAN §1 hub-and-spoke, all such
    CRs live on the mgmt cluster's K8s API. Assignment is SKIPPED
    on every non-mgmt cluster. Published as the
    `KARGO_MGMT_UAMI_PRINCIPAL_ID` fleet-scope repo variable.
  EOT
  type        = string
  nullable    = false
}

variable "kargo_aad_application_object_id" {
  description = <<-EOT
    Directory object id of the Kargo AAD application, owned by Stage 0.
    Consumed ONLY by the **management cluster's** Stage 1 plan as the
    `application_id` of the `azuread_application_password` resource
    that mints the `kargo-oidc-client-secret` written into the cluster
    KV (PLAN §4 Stage 1 lines 1769-1782). Workload clusters accept a
    null value here — the secret-rotation resources are gated on
    `local.mgmt_cluster`.
  EOT
  type        = string
  nullable    = true
}

variable "mgmt_aks_oidc_issuer_url" {
  description = <<-EOT
    OIDC issuer URL of the **management** cluster's AKS, used as the
    `issuer` field on the three `fc-argocd-spoke-*` FICs that bind
    `uami-argocd-spoke-<cluster>` to the Argo controller SAs running
    on mgmt (PLAN §1 hub-and-spoke; PLAN §4 Stage 1 outputs).

    Published by the **mgmt** cluster's Stage 1 as the
    `MGMT_AKS_OIDC_ISSUER_URL` repo variable (the only place a Stage
    1 also writes repo vars). Spoke clusters consume it via TF_VAR_*
    in `tf-apply.yaml`.

    Required on spokes (cluster.role != "management"); accepted as
    null on mgmt itself (no spoke FICs are authored there).

    While the `stage0-publisher` GH App that publishes this var is
    gated `if: false`, the operator must populate it manually after
    the first successful mgmt-cluster Stage 1 apply. See
    `docs/adoption.md` for the bootstrap order.
  EOT
  type        = string
  nullable    = true
}

variable "fleet_env_uami_principal_id" {
  description = <<-EOT
    Principal id of the `uami-fleet-<env>` UAMI owned by
    `bootstrap/environment`. Stage 1 assigns `Azure Kubernetes Service
    RBAC Cluster Admin` on this cluster's AKS resource to this
    principalId so Stage 2 (which runs under the same identity) can
    apply kubernetes_* / helm_release resources via an AAD bearer token
    exchange against a local-accounts-disabled cluster (PLAN §4 Stage 1
    lines 1812-1817). Published as the `FLEET_ENV_UAMI_PRINCIPAL_ID`
    env-scope GH Environment variable.
  EOT
  type        = string
  nullable    = false
}

variable "env_monitor_workspace_id" {
  description = <<-EOT
    Full ARM id of the env-scope Azure Monitor Workspace
    (`amw-<fleet.name>-<env>`), owned by `bootstrap/environment`. Stage
    1 binds the per-cluster Prometheus DCR to it and assigns
    `Monitoring Metrics Publisher` on it to the cluster UAMI so the
    AKS managed-prometheus addon can push scraped metrics. Published
    as the `MONITOR_WORKSPACE_ID` env-scope GH Environment variable.
  EOT
  type        = string
  nullable    = false
}

variable "env_dce_id" {
  description = <<-EOT
    Full ARM id of the env-scope Data Collection Endpoint
    (`dce-<fleet.name>-<env>`), owned by `bootstrap/environment`. Stage
    1's per-cluster Prometheus DCR references it as
    `dataCollectionEndpointId`; the paired DCE association on the AKS
    resource (name `configurationAccessEndpoint`) tells the scraper
    where to push. Published as the `DCE_ID` env-scope GH Environment
    variable.
  EOT
  type        = string
  nullable    = false
}

variable "env_action_group_id" {
  description = <<-EOT
    Full ARM id of the env-scope Action Group (`ag-<fleet.name>-<env>`),
    owned by `bootstrap/environment`. Passed through to
    `modules/cluster-monitoring` for alerting rule wiring (today the
    module ships recording rules only; the Action Group id is a
    no-op placeholder until the alert rule bodies land — PLAN §4
    Stage 1 lines 1872-1878). Published as the `ACTION_GROUP_ID`
    env-scope GH Environment variable.
  EOT
  type        = string
  nullable    = false
}
