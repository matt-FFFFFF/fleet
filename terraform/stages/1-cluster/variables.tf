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
#      networking subnet/pod CIDRs, etc.). All structure is documented in
#      config-loader/load.sh's header comment.
#
#   2. Named variables below — the handful of pre-created Azure resource
#      ids this stack must reference but cannot author itself. These are
#      populated from repo-environment variables by the `tf-apply.yaml`
#      workflow (PLAN §10; not yet implemented — piping is documentation
#      today, wired when the workflow lands):
#
#        env_region_vnet_resource_id  ← <ENV>_<REGION>_VNET_RESOURCE_ID
#                                       (bootstrap/environment)
#        mgmt_vnet_resource_id        ← MGMT_VNET_RESOURCE_ID
#                                       (bootstrap/fleet → fleet-meta
#                                       GitHub environment variable)
#        node_asg_resource_id         ← <ENV>_<REGION>_NODE_ASG_RESOURCE_ID
#                                       (bootstrap/environment)
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

variable "mgmt_vnet_resource_id" {
  description = <<-EOT
    Full ARM id of the fleet-wide mgmt VNet (`vnet-<fleet.name>-mgmt`)
    owned by `bootstrap/fleet`. Linked to this cluster's private DNS
    zone so in-cluster hostnames resolve from the mgmt plane (Kargo,
    fleet-wide tooling, platform CI). Published as the fleet-scope
    `MGMT_VNET_RESOURCE_ID` variable on the `fleet-meta` GitHub
    Environment directly by `bootstrap/fleet` (no Stage 0 hop).
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
