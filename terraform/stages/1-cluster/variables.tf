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
