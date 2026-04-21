# Onboarding a new AKS cluster

Operator walkthrough for adding a cluster to an existing, bootstrapped
fleet. One reviewed PR creates the cluster; `tf-apply.yaml` runs
Stage 1 (subnets + AKS + per-cluster private DNS zone) and Stage 2
(ArgoCD bootstrap) in a single matrix leg on merge.

Prerequisites:

- The fleet is initialized (`docs/adoption.md` §2) and
  `bootstrap/{fleet,environment}` have applied against the target env
  and region (`vnet-<fleet>-<env>-<region>` exists; the env-region ASG
  `asg-nodes-<env>-<region>` exists; mgmt↔env peering is up).
- The target env-region has a declared
  `networking.envs.<env>.regions.<region>.{address_space, pod_cidr_slot}`
  in `clusters/_fleet.yaml`.

## 1. Scaffold the cluster directory

```sh
cp -r clusters/_template clusters/<env>/<region>/<name>/
```

The path must have exactly four components under `clusters/`:
`<env>/<region>/<name>/cluster.yaml`. `<env>` must be one of
`mgmt`, `nonprod`, `prod`; `<region>` must match an Azure region that
has an `address_space` declared for this `<env>` in `_fleet.yaml`;
`<name>` is the cluster slug used in every derived resource name
(`uami-<name>-cp`, `snet-aks-api-<name>`, the per-cluster private DNS
zone, etc.).

## 2. Pick a `subnet_slot`

`cluster.yaml.networking.subnet_slot` is the **single** per-cluster
knob the operator picks. It is a non-negative integer that indexes
both per-cluster subnets and the per-cluster pod CIDR:

- `snet-aks-api-<name>` — `/28` at index `i` of the env VNet's API
  pool (delegated to `Microsoft.ContainerService/managedClusters`).
- `snet-aks-nodes-<name>` — `/25` at index `i` of the env VNet's
  nodes pool (Azure CNI Overlay + Cilium).
- `pod_cidr` — `100.[64 + pod_cidr_slot*16 + subnet_slot].0.0/16`
  in CGNAT (`pod_cidr_slot` comes from the env-region's `_fleet.yaml`
  block; see `docs/networking.md` "Pod CIDR allocation").

### Rules

1. **Required.** Every `cluster.yaml` carries
   `networking.subnet_slot: <int>`. The scaffold ships
   `subnet_slot: 0`; edit to the value you pick.
2. **Range.** `0 ≤ subnet_slot < capacity`, where
   `capacity = min(16, 2 * (2^(24-N) - 2))` for an env VNet of size
   `/N`. `/20` → 16 slots (API-pool bound); `/21` → 10; `/22` → 4.
3. **Unique per `(env, region)`.** Two clusters in the same
   env-region may not share a slot. Slots may freely repeat across
   different env-regions (they carve disjoint VNets).
4. **Immutable once merged.** Changing `subnet_slot` in-place forces
   replacement of both per-cluster subnets, which in turn forces AKS
   cluster destroy/recreate. The PR-check blocks the diff; the
   supported migration path is to create a new cluster at the new
   slot, cut traffic over, and retire the old one.

### Picking a slot

Enumerate existing slots in the target env-region:

```sh
yq '.networking.subnet_slot' clusters/<env>/<region>/*/cluster.yaml
```

Pick the lowest free integer. Keeping slots dense simplifies the
capacity story — scattered slot allocation does not reclaim
addresses, it just wastes them.

### When you hit capacity

At `/20`, an env-region holds 16 clusters. When the 17th is needed:

1. **Preferred — add a second region.** Edit `_fleet.yaml` to
   declare a new `networking.envs.<env>.regions.<new-region>.*`
   block (including a fleet-unique `pod_cidr_slot`) and run
   `env-bootstrap.yaml` for that env. New clusters land under
   `clusters/<env>/<new-region>/...` starting at `subnet_slot: 0`.
2. **Rarely — widen the pool shape.** Requires an amendment to
   PLAN §3.4 plus synchronized edits to `docs/naming.md`,
   `terraform/config-loader/load.sh`, and
   `terraform/modules/fleet-identity/main.tf`. Do not attempt this
   without a plan review.

## 3. Edit `cluster.yaml`

Beyond `subnet_slot`, fill in:

- `cluster.name` — must match the directory name.
- `cluster.env` / `cluster.region` — must match the directory path.
- `cluster.resource_group` — typically `rg-<name>`; this RG is
  created by Stage 1 and owns the AKS cluster.
- `cluster.aks.<key>` — any of the curated typed passthroughs
  exposed by `modules/aks-cluster/variables.tf` (today:
  `kubernetes_version`, `sku_tier`, `auto_scaler_profile`,
  `auto_upgrade_profile`, `maintenance_window`, `system_pool`,
  `apps_pool`). **Adding a new knob = adding a variable to
  `modules/aks-cluster/variables.tf`** and opening that PR first;
  there is no freeform passthrough map. See PLAN §3.4 "Stage 1 AKS
  module passthrough".
- RBAC group references, workload UAMIs, etc. — see
  `clusters/_template/cluster.yaml` for the full list of optional
  overrides.

Private DNS is **derived**. The cluster's zone is
`<name>.<region>.<env>.<dns.fleet_root>`, created by Stage 1 via
`terraform/modules/cluster-dns/` with `virtualNetworkLink`s to the
env VNet **and** the mgmt VNet. The legacy
`networking.dns_linked_vnet_ids` field in `cluster.yaml` is gone —
both VNet ids are sourced from repo variables (`MGMT_VNET_RESOURCE_ID`
and `<ENV>_<REGION>_VNET_RESOURCE_ID`) published by the owning
bootstrap stages.

## 4. Open the PR

```sh
git checkout -b feat/cluster-<name>
git add clusters/<env>/<region>/<name>/
git commit -m "feat(cluster): add <env>/<region>/<name>"
git push -u origin feat/cluster-<name>
gh pr create
```

`validate.yaml` runs on the PR. `.github/scripts/validate-subnet-slots.sh`
enforces the four rules above against every `cluster.yaml` in the
tree, diffing your branch against the PR base for the immutability
check. If the PR-check fails on capacity or uniqueness, pick a
different slot; if it fails on immutability, revert the slot change
on the existing cluster and add a new cluster instead.

## 5. Merge → apply

On merge, `tf-apply.yaml` runs one matrix leg for your cluster:

1. **Stage 1** (`terraform/stages/1-cluster`):
   - `azapi_resource.snet_aks_api` + `snet_aks_nodes` as children
     of the env VNet (parent id from `<ENV>_<REGION>_VNET_RESOURCE_ID`).
   - AVM AKS module (`Azure/avm-res-containerservice-managedcluster/azurerm ~> 0.5`)
     with curated-typed `cluster.aks.*` inputs, node pool attached
     to the env-region ASG (`<ENV>_<REGION>_NODE_ASG_RESOURCE_ID`).
   - Per-cluster private DNS zone + two `virtualNetworkLink`s
     (`env`, `mgmt`).
2. **Stage 2** (`terraform/stages/2-bootstrap`):
   - ArgoCD / Kargo bootstrap.

Total wall-clock: AKS creation dominates (~15 min). The PR itself is
the audit record; no follow-up manual apply is required.

## 6. Retiring a cluster

1. Remove the `clusters/<env>/<region>/<name>/` directory in a PR.
2. `tf-apply.yaml` destroys Stage 2 then Stage 1 resources for that
   cluster (including the AKS cluster, its subnets, and its private
   DNS zone). The env-region VNet, ASG, and peerings are untouched.
3. The retired slot is immediately reusable by a future cluster in
   the same env-region — the PR-check compares against the merged
   state, so deletion + re-add in a later PR is supported.

Do **not** rename a cluster directory in-place: `<name>` feeds every
derived resource name (subnets, UAMIs, zone FQDN), so a rename is
a full destroy/recreate. Add a new cluster and retire the old one.
