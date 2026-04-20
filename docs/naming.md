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
- `fleet.primary_region` — default Azure region.
- `environments.<env>.subscription_id` — one per env.
- `dns.fleet_root` — parent DNS zone (e.g. `int.acme.example`).
- Optional overrides: `acr.name_override`, `keyvault.name_override`,
  `state.storage_account_name_override`.
- For networking derivations (PLAN §3.4):
  `networking.vnets.mgmt.address_space` (mgmt VNet), and
  `networking.envs.<env>.regions.<region>.address_space` (each env-region
  VNet). Both `/20` by default.

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
| Mgmt VNet                 | `vnet-<fleet.name>-mgmt`                                              |                      |
| Env VNet (per region)     | `vnet-<fleet.name>-<env>-<region>`                                    |                      |
| Mgmt network RG           | `rg-net-mgmt`                                                         |                      |
| Env network RG            | `rg-net-<env>`                                                        |                      |
| Mgmt snet-pe-shared CIDR  | first `/26` of `networking.vnets.mgmt.address_space`                  |                      |
| Mgmt snet-runners CIDR    | second `/26` of `networking.vnets.mgmt.address_space`                 | mgmt VNet only       |
| Env snet-pe-env CIDR      | first `/26` of `networking.envs.<env>.regions.<region>.address_space` |                      |
| Cluster `/24` (slot K)    | K-th `/24` **after** the reserved first `/24` of the env VNet (see §3.4 diagram); i.e. `cidrsubnet(address_space, 24-N, K+1)` | K = `cluster.yaml.networking.subnet_slot`; 0 ≤ K < capacity |
| snet-aks-api CIDR         | first `/25` of the cluster `/24`                                      |                      |
| snet-aks-nodes CIDR       | second `/25` of the cluster `/24`                                     |                      |
| snet-aks-api subnet       | `snet-aks-api-<cluster.name>`                                         |                      |
| snet-aks-nodes subnet     | `snet-aks-nodes-<cluster.name>`                                       |                      |
| Env PE NSG                | `nsg-pe-env-<env>-<region>`                                           |                      |
| Mgmt shared NSG           | `nsg-pe-shared`                                                       |                      |
| Mgmt runner NSG           | `nsg-runners`                                                         |                      |
| env→mgmt peering          | `peer-<env>-<region>-to-mgmt`                                         | env state            |
| mgmt→env peering          | `peer-mgmt-to-<env>-<region>`                                         | env state (reverse)  |
| Node ASG (per env-region) | `asg-nodes-<env>-<region>`                                            |                      |

### Cluster slot capacity

For an env-region VNet of size `/N`:

- reserved /26s consume the first `/24` of the VNet;
- usable cluster slots = `2^(24-N) - 1`;
- at the default `/20` that's **15** slots (0..14).

A wider VNet (`/19`, `/18`) linearly raises capacity; operators widen
the VNet in `_fleet.yaml.networking.envs.<env>.regions.<region>.address_space`
if they outgrow 15 clusters per env-region (alternative: add a second
region under that env).

## Truncation

Where a hard Azure limit exists (KV ≤ 24, SA ≤ 24), the implementation
truncates from the right after the formula produces the candidate name.
`init-fleet.sh` validates `fleet.name` so the default formulas always
fit — adopters choosing overrides must self-validate.

## Override semantics

Overrides bypass the formula completely. No prefix/suffix is added.
The adopter is responsible for uniqueness and length limits.
