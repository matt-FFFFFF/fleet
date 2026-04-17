# Resource name derivation

Canonical, implementation-neutral spec. Implemented in:

- `terraform/config-loader/load.sh` (for Stage 1/2 consumers)
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

For Stage 1, `cluster.{name,env,region}` come from the cluster's
directory path under `clusters/`.

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
| Cluster DNS zone FQDN     | `<cluster.name>.<cluster.region>.<cluster.env>.<dns.fleet_root>`      |                      |

## Truncation

Where a hard Azure limit exists (KV ≤ 24, SA ≤ 24), the implementation
truncates from the right after the formula produces the candidate name.
`init-fleet.sh` validates `fleet.name` so the default formulas always
fit — adopters choosing overrides must self-validate.

## Override semantics

Overrides bypass the formula completely. No prefix/suffix is added.
The adopter is responsible for uniqueness and length limits.
