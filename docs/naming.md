# Resource name derivation

Canonical, implementation-neutral spec. Implemented in:

- `terraform/modules/fleet-identity/` (fleet-scope + env-scope HCL
  derivations, consumed by `bootstrap/fleet` and `bootstrap/environment`)
- `terraform/config-loader/load.sh` (Stage 1/2 consumers; carries
  cluster-scope CIDR derivations that need `cluster.subnet_slot`)
- `terraform/bootstrap/fleet/**` and `terraform/bootstrap/environment/**` HCL
  locals
- The self-test CI diffs outputs from both implementations against
  `.github/fixtures/adopter-test.tfvars`.

## Inputs

All derivations read `clusters/_fleet.yaml` — produced by `init-fleet.sh`
from `init/templates/_fleet.yaml.tftpl` during adoption. The relevant
fields:

- `fleet.name` — short slug, `^[a-z][a-z0-9]{1,11}$` (≤12 chars).
- `envs.<env>.subscription_id` — one per env (top-level `envs:` block).
- `networking.envs.<env>.regions.<region>.address_space` — one `/20`
  (or wider) per env-region VNet, as a YAML list of CIDR strings.
  Every env — including `mgmt` — has a `regions.<region>` map; there
  is no separate `networking.vnets.mgmt` block.
- `networking.envs.<env>.regions.<region>.hub_network_resource_id` —
  optional ARM id of the adopter-owned hub VNet this env-region peers
  to. Null ⇒ opt out of hub peering for that env-region.
- `networking.envs.<env>.regions.<region>.egress_next_hop_ip` —
  optional private IP of the hub firewall / NVA. Null ⇒ the
  per-env-region route table shell is empty (no `0.0.0.0/0` entry).
- `dns.fleet_root` — parent DNS zone (e.g. `int.acme.example`).
- Optional overrides: `acr.name_override`, `keyvault.name_override`,
  `state.storage_account_name_override`.
- Pod IPs use a shared fleet-wide `/16` (`100.64.0.0/16` in CGNAT)
  hard-coded in `modules/aks-cluster`; no per-region pod-CIDR slot is
  declared (see PLAN §3.4 Implementation status for rationale).
- `fleet.primary_region` is **not** a `_fleet.yaml` field — it is
  consumed only at `init/` render-time to fan per-env inputs into
  `networking.envs.<env>.regions.<primary_region>.*`.

For Stage 1, `cluster.{name,env,region}` come from the cluster's
directory path under `clusters/`, and `cluster.networking.subnet_slot`
from the cluster.yaml itself (required, immutable — see PLAN §3.4).

## Derived names

| Resource                  | Formula                                                               | Constraint           |
| ------------------------- | --------------------------------------------------------------------- | -------------------- |
| Fleet state SA            | override else `st<fleet.name>tfstate`                                 | ≤ 24 chars, a-z0-9   |
| Fleet state RG            | `rg-fleet-tfstate`                                                    |                      |
| Fleet state container     | `tfstate-fleet`                                                       |                      |
| Env state container       | `tfstate-<env>`                                                       |                      |
| Cluster state container   | `tfstate-cluster-<cluster.name>`                                      |                      |
| Fleet ACR                 | override else `acr<fleet.name>shared`                                 | ≤ 50 chars, a-z0-9   |
| Fleet KV                  | override else `kv-<fleet.name>-fleet`                                 | ≤ 24 chars           |
| Cluster KV                | override (per-cluster `platform.keyvault.name`) else `kv-<cluster.name>` | ≤ 24 chars, trunc |
| Fleet shared RG           | `rg-fleet-shared`                                                     |                      |
| Env shared RG             | `rg-fleet-<env>-shared`                                               |                      |
| Env DNS RG                | `dns.resource_group_pattern` with `{env}` substituted (default `rg-dns-<env>`) | |
| Env observability RG      | `rg-obs-<env>`                                                        |                      |
| Cluster RG                | declared in `cluster.yaml` (`cluster.resource_group`)                 |                      |
| UAMI — fleet stage0       | `uami-fleet-stage0`                                                   |                      |
| UAMI — fleet meta         | `uami-fleet-meta`                                                     |                      |
| UAMI — fleet runners      | `uami-fleet-runners`                                                  |                      |
| UAMI — per-env CI         | `uami-fleet-<env>`                                                    |                      |
| UAMI — Kargo mgmt         | `uami-kargo-mgmt`                                                     |                      |
| UAMI — cluster CP         | `uami-<cluster.name>-cp`                                              |                      |
| UAMI — cluster kubelet    | `uami-<cluster.name>-kubelet`                                         |                      |
| UAMI — workload (per svc) | `uami-<cluster.name>-workload-<svc>`                                  |                      |
| AMW (Azure Monitor WS)    | `amw-<fleet.name>-<env>`                                              |                      |
| DCE                       | `dce-<fleet.name>-<env>`                                              |                      |
| Grafana                   | `amg-<fleet.name>-<env>`                                              |                      |
| NSP                       | `nsp-<fleet.name>-<env>`                                              |                      |
| Grafana PE                | `pe-amg-<fleet.name>-<env>`                                           |                      |
| Action Group              | `ag-<fleet.name>-<env>`                                               |                      |
| Runner ACR (per-pool)     | `acrfleetrunners` (module-derived from `postfix = "fleet-runners"`, hyphens stripped) | ≤ 50 chars, a-z0-9 |
| Runner ACA environment    | `cae-fleet-runners`                                                   |                      |
| Cluster DNS zone FQDN     | `<cluster.name>.<cluster.region>.<cluster.env>.<dns.fleet_root>`      |                      |
| Env-region VNet           | `vnet-<fleet.name>-<env>-<region>` (uniform across envs incl. mgmt)   |                      |
| Env-region network RG     | `rg-net-<env>-<region>` (uniform across envs incl. mgmt)              |                      |
| Env-region route table    | `rt-aks-<env>-<region>` (associated with both the api and nodes subnets; `0.0.0.0/0` next-hop `egress_next_hop_ip`) | authored unconditionally by `bootstrap/environment`; `0.0.0.0/0` route entry only created when `egress_next_hop_ip` is non-null |
| Env-region node ASG       | `asg-nodes-<env>-<region>`                                            |                      |
| Env-region PE NSG         | `nsg-pe-env-<env>-<region>` (uniform across envs incl. mgmt)          |                      |
| Mgmt-only PE-fleet NSG    | `nsg-pe-fleet-<region>` (only on env=mgmt)                            |                      |
| Mgmt-only runners NSG     | `nsg-runners-<region>` (only on env=mgmt)                             |                      |
| snet-pe-env CIDR          | first `/26` of first `/24` of `networking.envs.<env>.regions.<region>.address_space`; i.e. `cidrsubnet(cidrsubnet(A, 24-N, 0), 2, 0)` | uniform across envs incl. mgmt |
| snet-pe-fleet CIDR        | `/26` at index 8 of the upper `/(N+1)` of A; i.e. `cidrsubnet(cidrsubnet(A, 1, 1), 25-N, 8)` | mgmt env-region only (fleet-plane zone); hosts tfstate SA, fleet KV, fleet ACR PEs |
| snet-runners CIDR         | first `/23` of the upper `/(N+1)` of A; i.e. `cidrsubnet(cidrsubnet(A, 1, 1), 22-N, 0)` | mgmt env-region only; ACA-delegated |
| Cluster API subnet CIDR   | i-th `/28` of the env VNet's **API pool** (second `/24` of address_space); i.e. `cidrsubnet(cidrsubnet(A, 24-N, 1), 28-24, i)` | i = `cluster.yaml.networking.subnet_slot`; 0 ≤ i < 16; delegated to `Microsoft.ContainerService/managedClusters` (AKS requires exactly `/28`) |
| Cluster nodes subnet CIDR | i-th `/25` of the env VNet's **nodes pool** (third `/24` of address_space onward); i.e. `cidrsubnet(cidrsubnet(A, 24-N, 2 + (i/2)), 25-24, i%2)` | i = `cluster.yaml.networking.subnet_slot`; 0 ≤ i < capacity; sized for Azure CNI Overlay + Cilium (pod IPs come from `pod_cidr`, not this subnet) |
| Cluster pod CIDR          | `100.64.0.0/16` (fleet-wide constant)                                 | CGNAT 100.64.0.0/10; non-routable — consumed by Azure CNI Overlay (+ Cilium); shared across all clusters since pod IPs never appear on the wire (see "Pod CIDR (shared)" below) |
| snet-aks-api subnet       | `snet-aks-api-<cluster.name>`                                         |                      |
| snet-aks-nodes subnet     | `snet-aks-nodes-<cluster.name>`                                       |                      |
| env→mgmt peering          | `peer-<env>-<region>-to-mgmt-<mgmt-region>`                           | authored from env state for every non-mgmt env-region |
| mgmt→env peering          | `peer-mgmt-<mgmt-region>-to-<env>-<region>`                           | reverse half of the above, gated on `create_reverse_peering` |

### Cluster slot capacity

For an env-region VNet of size `/N`, the two-pool layout (see PLAN
§3.4) reserves:

- the first `/24` of the VNet for PE/runners subnets;
- the second `/24` for the **API pool** (16 × `/28`, each delegated to
  `Microsoft.ContainerService/managedClusters`);
- the remaining `2^(24-N) - 2` `/24`s for the **nodes pool**, each
  yielding 2 × `/25`.

Usable cluster slots:

```
capacity = min(16, 2 * (2^(24-N) - 2))
```

- `/20` → `min(16, 26)` = **16** (api pool is the cap)
- `/19` → `min(16, 58)` = **16** (still api-bound; widening the VNet
  beyond `/20` does not raise capacity since the api pool is a fixed
  `/24` holding 16 `/28`s)
- `/21` → `min(16, 12)` = **12**
- `/22` → `min(16, 4)`  = **4**

Operators hitting the 16-cluster-per-env-region cap add another
region (preferred) or open a PR that changes the pool shape in
PLAN §3.4 / this file / `config-loader/load.sh` / `fleet-identity`
together.

Azure CNI Overlay + Cilium is assumed: pod IPs come from a shared
fleet-wide `/16` in CGNAT (`100.64.0.0/16`; see "Pod CIDR (shared)"
below), not from the nodes subnet, so `/25` nodes subnets are
comfortably sized for realistic node counts and ILBs.

### Pod CIDR (shared 100.64.0.0/16)

Every cluster in the fleet uses the same pod CIDR: `100.64.0.0/16`,
hard-coded in `modules/aks-cluster/main.tf`. Cross-cluster uniqueness
buys nothing — pod IPs are non-routable outside the node (Azure CNI
Overlay SNATs to the node IP on egress), and observability queries
disambiguate by `_ResourceId` / cluster name rather than source IP.
Collapsing the earlier per-cluster `pod_cidr_slot` machinery (`/12`
envelope, loader derivation, fleet-identity passthrough) eliminates
the hard 16-env-region fleet cap and the allocation grid. If
ClusterMesh or any cross-cluster pod routing is introduced later, the
pod CIDR becomes a per-cluster input again; the rationale is recorded
in PLAN §3.4 Implementation status.

**`100.127.0.0/16` is reserved fleet-wide** for the AKS `service_cidr`
(virtual in-cluster ClusterIP pool; DNS at `100.127.0.10`). The
shared pod `/16` at `100.64.0.0/16` is disjoint from it by
construction. See `docs/networking.md` § "Service CIDR" and PLAN §3.4.

### Service CIDR (reserved 100.127.0.0/16)

`service_cidr` is the in-cluster virtual pool from which Kubernetes
draws ClusterIPs. It never appears on any wire — kube-proxy (Cilium
here) rewrites ClusterIP → pod IP at packet dispatch. Because the
pool is virtual, *sharing one /16 across all clusters in the fleet is
safe*: each cluster's ClusterIPs are only meaningful inside that
cluster's dataplane.

The hazard is overlap with any **real** address reachable from pods:
if `service_cidr` sits inside a VNet's `address_space`, a pod trying
to talk to an actual VM at that address gets DNATed to a random
pod instead. Placing `service_cidr` in CGNAT guarantees disjointness
from any adopter VNet (which must be RFC-1918 per `init/variables.tf`
validation).

- Hard-coded at `100.127.0.0/16` in `modules/aks-cluster/main.tf`
  (`dns_service_ip = 100.127.0.10`).
- Disjoint from the shared pod `/16` at `100.64.0.0/16` by
  construction.

## Truncation

Where a hard Azure limit exists (KV ≤ 24, SA ≤ 24), the implementation
truncates from the right after the formula produces the candidate name.
`init-fleet.sh` validates `fleet.name` so the default formulas always
fit — adopters choosing overrides must self-validate.

## Override semantics

Overrides bypass the formula completely. No prefix/suffix is added.
The adopter is responsible for uniqueness and length limits.
