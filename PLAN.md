# Fleet Repository — Implementation Plan

Source of truth for building out the `fleet` monorepo: Terraform-driven AKS
cluster provisioning, per-cluster ArgoCD bootstrap, platform GitOps, team
tenancy via AppProjects, and Kargo-driven promotion for both platform and
team workloads.

Derived from the inspiration module at
`terraform-azure-avm-ptn-aks-argocd`, extended to also provision clusters,
manage upgrades, and add Kargo promotion.

---

## 1. Decisions (locked)

| Area                            | Decision                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                |
| ------------------------------- | ----------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| Cluster type                    | AKS only                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                |
| Directory hierarchy             | `clusters/<env>/<region>/<name>/cluster.yaml` with `_defaults.yaml` merged at fleet → env → region → cluster                                                                                                                                                                                                                                                                                                                                                                                                                                                            |
| Terraform state                 | One state per cluster per stage                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                         |
| Cluster upgrades                | In-place; `kubernetes.version` pinned in `cluster.yaml`; TF apply drives upgrade                                                                                                                                                                                                                                                                                                                                                                                                                                                                                        |
| Bootstrap staging               | Two Terraform stages per cluster (`1-cluster`, `2-bootstrap`)                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                           |
| Argo topology                   | Per-cluster ArgoCD                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                      |
| Cluster authn/authz             | **Entra-only**: `disableLocalAccounts=true`, `aadProfile.managed=true`, `aadProfile.enableAzureRBAC=true`. No local kubeconfigs ever issued. Access to the Kubernetes API is gated entirely by AAD tokens + Azure RBAC for Kubernetes Authorization. Per-env break-glass AAD group set as `adminGroupObjectIDs`.                                                                                                                                                                                                                                                        |
| Git provider                    | GitHub only                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                             |
| Secrets / identity              | Azure Workload Identity + External Secrets Operator + Key Vault                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                         |
| Team mapping                    | Teams declared globally in `platform-gitops/config/teams/<team>.yaml`, opted into clusters per team                                                                                                                                                                                                                                                                                                                                                                                                                                                                     |
| Team repo constraint            | One team repo + one shared OCI chart repo                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                               |
| Team namespace scope            | Namespace prefix wildcard `<team>-*`. Team name = filename basename of `platform-gitops/config/teams/<team>.yaml`; namespace prefix = team name (both derived, not declared). Validated in CI.                                                                                                                                                                                                                                                                                                                                                                                      |
| Argo UI RBAC                    | Per-team OIDC group → AppProject `role/admin`                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                           |
| Repo layout                     | Monorepo (Terraform + platform-gitops), team repos separate                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                             |
| CI/CD                           | GitHub Actions — PR = plan, merge to main = apply                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                       |
| Scale target                    | 5–20 clusters, 10–50 teams                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                              |
| Kargo control plane             | Single Kargo on a dedicated management cluster                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                          |
| Kargo Stage granularity         | Env-based: `dev` / `staging` / `prod`                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                   |
| Promotion trigger               | Auto to `dev`; manual onward                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                            |
| Commit style                    | Direct commit for non-prod; PR for prod                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                 |
| Verification                    | Argo CD App health                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                      |
| Platform promotion scope        | All platform components                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                 |
| Team repo layout                | `services/<app>/environments/<env>/values.yaml`                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                         |
| Kargo resources per team        | Auto-generated from `config/teams/<team>.yaml`                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                          |
| Kargo GitHub auth               | Dedicated GitHub App; PEM in Key Vault; synced by ESO                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                   |
| Kargo RBAC                      | Same `oidcGroup` as Argo                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                |
| Container registry              | One ACR per fleet; hosts images and Helm OCI charts                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                     |
| Key Vault                       | Two-tier: one **fleet KV** created by `bootstrap/fleet` (Stage -1, alongside the tfstate SA and runner pool — co-located to break the runner-pool KV-reference cycle) strictly for secrets consumed by more than one cluster (e.g., Argo GitHub App PEM, Argo OIDC client secret, runner-pool GH App PEM); **one cluster KV per cluster** (Stage 1) for cluster-local secrets. Stage 0 owns *seeding and rotating* secrets into the fleet KV (`Key Vault Secrets Officer` role assignment on the vault). Mgmt-cluster-only secrets (Kargo GitHub App PEM, Kargo OIDC client secret) live in the mgmt cluster's KV, not the fleet KV.                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                            |
| AAD app registrations           | Managed by Terraform (Stage 0) — one for Argo, one for Kargo. Each app carries **Federated Identity Credentials** keyed off every cluster's OIDC issuer URL (subjects: Argo/Kargo ServiceAccounts) so workload→AAD calls are secret-less. A **single residual `client_secret` per app** remains, used **only** by the OIDC RP auth-code flow for human login (Argo/Dex upstream don't yet support `client_assertion` RP auth); auto-rotated on every Stage 0 apply with a short TTL.                                                                                    |
| Residual long-lived secrets     | **Exactly one class**: the Argo and Kargo AAD-app `client_secret` values used by their OIDC RP auth-code flows (human login). Stored in fleet KV, rotated on every Stage 0 apply (`end_date_relative` short TTL), reflected to cluster via ESO, picked up by Argo/Kargo on restart. All other fleet credentials — CI→Azure, workload→Azure, CI→Graph, AAD-app→Azure (`client_credentials`) — are federated and secret-less. Tracked in §15 with upstream removal trigger.                                                                                               |
| Metrics                         | **Azure Managed Prometheus** — one **Azure Monitor Workspace per env** (created by `bootstrap/environment`) plus a **Data Collection Endpoint** per env; both are members of a per-env **Network Security Perimeter** (no public ingress). Each cluster gets a DCR + DCRA in Stage 1 pointing at its env's DCE+AMW; AKS `azureMonitorProfile.metrics` enabled; the env NSP inbound rule admits the env subscription so cluster addon identities can ingest.                                                                                                             |
| Dashboards                      | **Azure Managed Grafana** — one instance per env (created by `bootstrap/environment`) with **public network access disabled** and a standard **Private Endpoint** in the env hub VNet (private DNS zone `privatelink.grafana.azure.com`). AAD-auth; env's AMW wired as default data source via the native `azureMonitorWorkspaceIntegrations` child; Grafana's outbound to AMW/DCE is admitted by an **NSP inbound access rule** scoped to Grafana's subscription. Admin role granted to the env's `aad.grafana.admins` group.                                          |
| Alert routing                   | One Azure Monitor **Action Group** per env (prod → PagerDuty, nonprod → Slack); `prometheusRuleGroups` in Stage 1 reference the env-local AG by derived name                                                                                                                                                                                                                                                                                                                                                                                                            |
| Observability network isolation | **Network Security Perimeter** per env (`nsp-<fleet.name>-<env>`, resource `Microsoft.Network/networkSecurityPerimeters`) with AMW + DCE as members. Inbound access rules: (1) env cluster subscription → DCE (ingestion), (2) Grafana's subscription → AMW (query). Outbound rules default-deny.                                                                                                                                                                                                                                                                       |
| Management cluster sizing       | 2× `Standard_D4s_v5` in system pool (no apps pool)                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                      |
| Cluster autoscaler              | Enabled on all node pools via `min_count`/`max_count`; profile tunables in cluster config                                                                                                                                                                                                                                                                                                                                                                                                                                                                               |
| AKS Terraform module            | `Azure/avm-res-containerservice-managedcluster/azurerm` (pinned to an `azapi`-based version)                                                                                                                                                                                                                                                                                                                                                                                                                                                                            |
| Terraform providers             | `azapi` for all Azure ARM resources; **`hashicorp/azuread`** for AAD applications / federated identity credentials / client-secret rotation (typed-resource lifecycle is materially simpler than driving the low-level `microsoft/msgraph` provider via `msgraph_resource` + `addPassword`/`removePassword` action choreography); `integrations/github` for repo/env management; `kubernetes` + `helm` in Stage 2; `random` as needed. **No `azurerm`.** `azuread` is carved out specifically for AAD app lifecycle — all other Azure ARM operations remain on `azapi`. |
| CI credential scope             | Per GitHub environment; one dedicated UAMI per env (`fleet-stage0`, `fleet-mgmt`, `fleet-nonprod`, `fleet-prod`) plus a privileged `fleet-meta` for bootstrap ops. Azure RBAC scoped per env.                                                                                                                                                                                                                                                                                                                                                                           |
| Bootstrap model                 | `bootstrap/fleet` run locally once; `bootstrap/environment` and `bootstrap/team` run via GH Actions under the `fleet-meta` environment (2-reviewer gate).                                                                                                                                                                                                                                                                                                                                                                                                               |
| Stage 0 output propagation      | Published to repo variables by the Stage 0 workflow; Stage 1 consumes `vars.*`. **`terraform_remote_state` is never used.** Cross-stage values flow as follows: Stage 0 → Stage 1 via repo variables (fleet-wide, fan-out to many clusters); Stage 1 → Stage 2 via **in-job `terraform output -json` piped into `stage2.auto.tfvars.json`** (single cluster, single CI job). Stage 2 therefore makes zero Azure data-source calls at plan time. Fleet-wide singletons needed by per-cluster stages (e.g., the Kargo mgmt UAMI `principalId`) live in Stage 0 so they flow through the existing publish path — no Stage 1-to-Stage 1 cross-cluster propagation is required.                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                     |
| DNS for ingress                 | Opinionated: single `fleet_root` in `clusters/_fleet.yaml`; each cluster's private zone FQDN auto-derived from its directory path as `<name>.<region>.<env>.<fleet_root>`; linked to supplied VNets; external-dns scoped to its own zone only                                                                                                                                                                                                                                                                                                                           |
| Self-hosted CI runners          | Single shared repo-scoped GitHub Actions runner pool on **Azure Container Apps + KEDA** (label `self-hosted`), created by `bootstrap/fleet` via a vendored `Azure/terraform-azurerm-avm-ptn-cicd-agents-and-runners` module. Trust boundary is the GitHub Environment + federated credential (not the VNet). Per-pool private ACR; LAW; no NAT / no public IP (egress via UDR through the hub firewall). A dedicated `fleet-runners` GitHub App (`actions:read` + `metadata:read`) drives KEDA polling; its PEM lives in the fleet KV and is referenced into the Container App Job as a Key Vault secret reference (never plaintext). |
| `azurerm` carveout (runners)    | Narrow, **module-internal-only** carveout inside the vendored `terraform/modules/cicd-runners/` tree, mirroring the existing `azuread` carveout rationale: the upstream AVM module relies on `azurerm_container_app_job`, `azurerm_private_dns_*`, `azurerm_nat_*`, `azurerm_public_ip`, and the `Azure/avm-res-containerregistry-registry` child module. `bootstrap/fleet` itself authors zero `azurerm_*` resources or data sources — the `provider "azurerm"` block in `bootstrap/fleet/providers.tf` exists only because Terraform requires the parent to configure every provider any child references. |
| Secret retrieval                | Key Vault-reference on workload resources wherever the target service supports it (e.g. Container App Job `secret { keyVaultUrl + identity }`); **ephemeral `azapi_resource_action`** (confirmed on `azapi ~> 2.9`) whenever Terraform itself must read a KV secret to make an Azure API call that takes the plaintext. Plaintext KV secret values **never** enter Terraform state. Driver: `azurerm_container_app_job.secret.value` has no `write_only` on `azurerm 4.69.0`; `azurerm_key_vault_secret.value_wo` is present and is the preferred path for writes. |

---

## 2. Repository layout

```
fleet/
├── .github/workflows/
│   ├── validate.yaml               # fmt, tflint, yamllint, jsonschema, helm lint, kargo lint
│   ├── tf-plan.yaml                # PR: matrix plan per changed cluster
│   ├── tf-apply.yaml               # main: matrix apply; prod gated by GH Environments
│   ├── env-bootstrap.yaml          # workflow_dispatch → bootstrap/environment (fleet-meta)
│   └── team-bootstrap.yaml         # on new team YAML → bootstrap/team (fleet-meta or narrower)
│
├── terraform/
│   ├── bootstrap/
│   │   ├── fleet/                  # human-run once; seeds state SAs, fleet-stage0 + fleet-meta UAMIs, GH repo/env/vars
│   │   ├── environment/            # Actions-run; per-env UAMI + state container + GH environment + variables
│   │   └── team/                   # Actions-run; invokes GH module to mint team repo from template
│   ├── stages/
│   │   ├── 0-fleet/                # fleet-global: ACR + AAD app registrations
│   │   │   ├── backend.tf
│   │   │   ├── providers.tf
│   │   │   ├── variables.tf
│   │   │   ├── main.acr.tf
│   │   │   ├── main.aad.tf         # Argo + Kargo AAD apps, service principals
│   │   │   └── outputs.tf
│   │   ├── 1-cluster/              # AKS + UAMIs + KV access + DNS role assignments + ACR pull role
│   │   │   ├── backend.tf
│   │   │   ├── providers.tf
│   │   │   ├── variables.tf
│   │   │   ├── main.tf
│   │   │   └── outputs.tf
│   │   └── 2-bootstrap/            # ArgoCD + (mgmt only) Kargo repo-creds / OIDC secrets
│   │       ├── backend.tf
│   │       ├── providers.tf
│   │       ├── variables.tf
│   │       ├── main.tf
│   │       ├── main.argocd.tf
│   │       ├── main.kargo.tf       # conditional on cluster.role == "management"
│   │       └── outputs.tf
│   │
│   ├── modules/
│   │   ├── aks-cluster/            # wraps AVM avm-res-containerservice-managedcluster
│   │   ├── cluster-identities/     # UAMIs: external-dns, eso, per-team
│   │   ├── argocd-bootstrap/       # GitHub-only port of the inspiration module
│   │   └── cluster-dns/            # DNS Zone Contributor role assignments
│   │
│   └── config-loader/
│       └── load.sh                 # yq deep-merge _defaults.yaml chain → tfvars.json
│
├── clusters/
│   ├── _defaults.yaml              # fleet-wide defaults (incl. ACR reference)
│   ├── _template/                  # scaffold for `cp -r` onboarding
│   │   └── cluster.yaml
│   ├── _fleet.yaml                 # fleet-scope config consumed by Stage 0 (ACR name, AAD display names)
│   ├── mgmt/
│   │   └── eastus/aks-mgmt-01/cluster.yaml
│   ├── nonprod/
│   │   ├── _defaults.yaml
│   │   ├── eastus/
│   │   │   ├── _defaults.yaml
│   │   │   └── aks-nonprod-01/cluster.yaml
│   │   └── westeurope/
│   │       └── aks-nonprod-eu-01/cluster.yaml
│   └── prod/
│       ├── _defaults.yaml
│       └── eastus/aks-prod-01/cluster.yaml
│
├── platform-gitops/
│   ├── applications/               # Argo root children, ordered by sync-wave
│   │   ├── 00-eso.yaml
│   │   ├── 00-eso-cluster-secret-store.yaml
│   │   ├── 10-external-dns.yaml
│   │   ├── 10-gateway.yaml
│   │   ├── 10-tls-wildcard.yaml
│   │   ├── 20-observability.yaml
│   │   ├── 25-kargo.yaml           # ApplicationSet cluster-generator filtered to role=management
│   │   ├── 30-argocd-self-manage.yaml
│   │   └── 40-teams.yaml           # ApplicationSet matrix: teams × opted-in clusters
│   │
│   ├── components/
│   │   ├── argocd-self-manage/
│   │   │   ├── base/values.yaml
│   │   │   └── environments/{dev,staging,prod}/values.yaml
│   │   ├── eso/{base,environments/...}
│   │   ├── external-dns/{base,environments/...}
│   │   ├── gateway/{base,environments/...}
│   │   ├── observability/{base,environments/...}
│   │   ├── tls-wildcard/{base,environments/...}
│   │   ├── kargo/{base,environments/...}
│   │   └── teams/                  # team-resources Helm chart (templates in §7)
│   │
│   ├── kargo/
│   │   ├── projects/
│   │   │   ├── platform.yaml
│   │   │   └── teams/              # rendered via ApplicationSet / Helm from config/teams/*
│   │   ├── warehouses/
│   │   │   ├── platform/{argocd,eso,external-dns,gateway,observability,kargo,tls-wildcard}.yaml
│   │   │   └── teams/<team>/<service>.yaml
│   │   ├── stages/
│   │   │   ├── platform/{dev,staging,prod}.yaml
│   │   │   └── teams/<team>/{dev,staging,prod}.yaml
│   │   └── promotiontemplates/
│   │       ├── platform-nonprod.yaml
│   │       ├── platform-prod.yaml
│   │       ├── team-nonprod.yaml
│   │       └── team-prod.yaml
│   │
│   └── config/
│       ├── clusters/<env>-<region>-<name>.yaml   # cluster registry (labels drive ApplicationSet selectors)
│       └── teams/<team>.yaml                     # team registry — drives AppProject + Kargo Project
│
└── docs/
    ├── onboarding-cluster.md
    ├── onboarding-team.md
    ├── upgrades.md
    └── promotion.md
```

---

## 3. Cluster config schema

`clusters/<env>/<region>/<name>/cluster.yaml` — merged on top of
`_defaults.yaml` at each level by `terraform/config-loader/load.sh` via
`yq eval-all 'select(fileIndex==0) *d select(fileIndex==1) *d ...'`.

```yaml
cluster:
  name: aks-nonprod-01
  env: nonprod            # one of: mgmt | dev | staging | prod (mgmt only for role=management)
  role: workload          # one of: management | workload
  region: eastus
  subscription_id: 00000000-0000-0000-0000-000000000000
  resource_group: rg-aks-nonprod-eastus-01

kubernetes:
  version: "1.30"                    # bumping triggers control plane + node pool upgrade
  sku_tier: Standard
  node_image_upgrade: NodeImage
  control_plane_upgrade: patch
  cluster_autoscaler_profile:        # cluster-wide autoscaler tuning (optional; _defaults supplies)
    scale_down_delay_after_add: 10m
    scale_down_unneeded: 10m
    expander: least-waste
    max_graceful_termination_sec: 600

networking:
  # Per-cluster index into the env+region VNet's two subnet pools (see
  # §3.4). The operator picks an integer in [0..capacity-1] that is
  # unique within the env+region; the PR-check in `validate.yaml`
  # enforces uniqueness, range, and that the slot is never changed
  # in-place (changing it forces subnet re-creation → AKS re-create).
  # The slot indexes both pools simultaneously:
  #   snet-aks-api-<name>    = i-th /28 of the env VNet's API pool
  #   snet-aks-nodes-<name>  = i-th /25 of the env VNet's nodes pool
  # Both are owned by Stage 1 as azapi child resources of the env VNet.
  # At /20 env VNets, capacity = 16 (api pool is the hard cap).
  subnet_slot: 0
  pod_cidr: 10.244.0.0/16
  service_cidr: 10.0.0.0/16
  private_cluster: true
  # dns_linked_vnet_ids is derived — the cluster's private DNS zone is
  # linked to its env-region VNet and the mgmt env-region VNet in the
  # same region automatically by Stage 1 (mgmt clusters collapse to a
  # single link). No BYO link list.

node_pools:
  system:
    vm_size: Standard_D4s_v5
    min_count: 2
    max_count: 5
    zones: [1, 2, 3]
    enable_auto_scaling: true        # cluster autoscaler on
  apps:
    vm_size: Standard_D8s_v5
    min_count: 3
    max_count: 20
    zones: [1, 2, 3]
    enable_auto_scaling: true

platform:
  # keyvault is NOT declared per cluster. The cluster KV is created by
  # Stage 1 and named `kv-<cluster.name>` (derived). The fleet KV is
  # owned by `bootstrap/fleet` (Stage -1); its id/name flow to Stage 1
  # via the `vars.FLEET_KEYVAULT_{ID,NAME}` repo variables published
  # by Stage 0.
  acr:                                                           # fleet-wide; resolved from Stage 0 outputs
    login_server: acmefleet.azurecr.io
    resource_id: /subscriptions/.../registries/acmefleet
  # Optional override: `platform.keyvault.name` to override the derived name
  # Optional override: `platform.keyvault.resource_group` (defaults to cluster RG)
  # Optional override: `platform.dns.resource_group` (defaults to cluster RG)
  gitops:
    repo_url: https://github.com/acme/fleet
    path: platform-gitops
    revision: main
  argocd:
    helm_version: "9.5.0"
    oidc:
      issuer: https://login.microsoftonline.com/<tenant>/v2.0
      client_id_kv_secret: argocd-oidc-client-id
    github_app:
      app_id: "<id>"
      installation_id: "<id>"
      private_key_kv_secret: argocd-github-app-pem
  kargo:                             # honored only when cluster.role == "management"
    enabled: true
    helm_version: "1.0.5"
    oidc:
      issuer: https://login.microsoftonline.com/<tenant>/v2.0
      client_id_kv_secret: kargo-oidc-client-id
    github_app:
      app_id: "<id>"
      installation_id: "<id>"      private_key_kv_secret: kargo-github-app-pem
  observability:
    managed_prometheus:
      enabled: true                   # default true; set false to skip DCR+DCRA+addon on this cluster

teams:                               # drives Stage 1 per-team UAMI creation on this cluster
  - team-a
  - team-b
```

Fleet-level `_defaults.yaml` carries platform-wide constants
(`platform.gitops.repo_url`, `platform.argocd.helm_version`, etc.); env /
region / cluster files override only what they need.

### 3.1 Fleet config — `clusters/_fleet.yaml`

Fleet-scope configuration consumed by Stage 0 and referenced by Stage 1.
Declared once; operators do not re-state any of these values per cluster.

```yaml
fleet:
  name: acme # used in resource naming prefixes
  tenant_id: 00000000-0000-0000-0000-000000000000

acr:
  name: acmefleet # Stage 0 creates acmefleet.azurecr.io
  resource_group: rg-fleet-shared
  location: eastus
  sku: Premium

keyvault: # FLEET KV (one, created by bootstrap/fleet — Stage -1)
  name: kv-acme-fleet
  resource_group: rg-fleet-shared
  location: eastus
  # Stores: Argo/Kargo GH App PEMs, AAD OIDC client secrets, fleet-wide
  # pull creds, fleet-runners GH App PEM. Strictly private: public
  # network access disabled, default-deny network ACLs, private
  # endpoint supplied via networking.fleet_kv.private_endpoint.*
  # (operator-owned subnet + central privatelink.vaultcore.azure.net
  # zone, symmetric with the tfstate SA and runner ACR).
  # Per-cluster KVs are created by Stage 1 and named kv-<cluster.name>.

aad:
  argocd:
    display_name: fleet-argocd
    owners: [<object-id>, ...]
    group_claim_name: groups
  kargo:
    display_name: fleet-kargo
    owners: [<object-id>, ...]
    group_claim_name: groups
  grafana:
    # Per-env groups live under `envs.<env>.grafana` below.
    # The display_name / SKU / ZR defaults apply to every env instance.
    sku: Standard
    zone_redundancy: true
    api_key_enabled: false # AAD only; no API keys
    deterministic_outbound_ip: true
  aks:
    # Per-env AKS cluster-admin / operator groups live under
    # envs.<env>.aks below. Fleet-wide defaults here.
    tenant_id: <tenant-id> # AAD profile tenant (usually fleet.tenant_id)
    disable_local_accounts: true # hard requirement; AKS module input is pinned
    enable_azure_rbac: true # Azure RBAC for Kubernetes Authorization

networking:
  # Central private DNS zones for PE A-record registration. All BYO —
  # never created by this repo, only referenced by resource id.
  private_dns_zones:
    blob: /subscriptions/<sub-hub>/.../privatelink.blob.core.windows.net
    vaultcore: /subscriptions/<sub-hub>/.../privatelink.vaultcore.azure.net
    azurecr: /subscriptions/<sub-hub>/.../privatelink.azurecr.io
    grafana: /subscriptions/<sub-hub>/.../privatelink.grafana.azure.com
  # Env-tier VNets. One VNet per env-per-region for every env,
  # **including `mgmt`**. `bootstrap/fleet` owns its own resource
  # subnets inside the mgmt VNet (CI-plane PEs for tfstate SA, fleet
  # KV, fleet ACR, plus the ACA-delegated runner-pool Container App
  # Environment); `bootstrap/environment` owns the cluster-workload
  # subnets (api pool, nodes pool, env-PE) on every env VNet
  # uniformly, including mgmt. See §3.4.
  #
  # Each env-region entry carries a `hub_network_resource_id`
  # pointing at an adopter-owned hub VNet (not managed by this repo).
  # The sub-vending module emits a hub peering against this id.
  # Null opts the env-region out of hub peering entirely (e.g. when
  # an adopter has no hub in that region yet). Mgmt↔env peerings are
  # implicit: `bootstrap/environment` iterates every
  # `networking.envs.mgmt.regions.*` entry and peers each non-mgmt
  # env-region to the mgmt VNet in the same region (falling back to
  # the first mgmt region if no same-region mgmt VNet exists). Both
  # halves are authored from env state via the peering AVM module,
  # toggled by `create_reverse_peering` per env-region (default true).
  envs:
    mgmt:
      regions:
        eastus:
          address_space: ["10.50.0.0/20"]
          # Adopter-owned hub VNet this mgmt env-region peers into
          # (mgmt typically shares a non-prod or prod hub rather
          # than running its own). Null opts out of hub peering.
          hub_network_resource_id: /subscriptions/<sub-hub>/resourceGroups/rg-hub/providers/Microsoft.Network/virtualNetworks/vnet-hub-nonprod-eastus
          # Optional, default true. Set false when the hub is owned
          # by a team that forbids spoke-initiated reverse peerings
          # (in that case the hub team authors the reverse half
          # out-of-band and the sub-vending call only creates the
          # spoke→hub half).
          create_reverse_peering: true
    nonprod:
      regions:
        eastus:
          address_space: ["10.60.0.0/20"]
          hub_network_resource_id: /subscriptions/<sub-hub>/resourceGroups/rg-hub/providers/Microsoft.Network/virtualNetworks/vnet-hub-nonprod-eastus
          create_reverse_peering: true
        # westeurope:
        #   address_space: ["10.61.0.0/20"]
        #   hub_network_resource_id: null          # opt out of hub peering in this region
        #   create_reverse_peering: true
    prod:
      regions:
        eastus:
          address_space: ["10.70.0.0/20"]
          hub_network_resource_id: /subscriptions/<sub-hub>/resourceGroups/rg-hub/providers/Microsoft.Network/virtualNetworks/vnet-hub-prod-eastus
          create_reverse_peering: true

observability:
  # One stack per env. Names derived per env by the config-loader:
  #   AMW:      amw-<fleet.name>-<env>
  #   DCE:      dce-<fleet.name>-<env>
  #   Grafana:  amg-<fleet.name>-<env>
  #   NSP:      nsp-<fleet.name>-<env>
  #   PE:       pe-amg-<fleet.name>-<env>
  #   RG:       rg-obs-<env>                (in the env's subscription)
  #   AG:       ag-<fleet.name>-<env>       (Azure Monitor Action Group)
  # Override any name by setting envs.<env>.observability.*.name.
  network_isolation:
    mode: network_security_perimeter # AMW + DCE members; Grafana via PE
    nsp_profile_name: default
    # Grafana PE subnet is derived: first /26 of networking.envs.<env>.regions.<region>.address_space
    # (named snet-pe-env by docs/naming.md). No per-env subnet override surface.
  monitor_workspace:
    public_network_access: Disabled # enforced; NSP is the only ingress path
  data_collection_endpoint:
    public_network_access: Disabled
  action_group:
    short_name_prefix: acme # <=12 chars; env appended -> "acmeprod" etc.

envs:
  nonprod:
    subscription_id: <sub-fleet-nonprod>
    aks:
      # AAD break-glass list baked into every AKS in this env as
      # aadProfile.adminGroupObjectIDs. Members bypass K8s RBAC entirely.
      # Keep to a tight on-call / platform SRE group.
      admin_groups: [<group-object-id>] # grp-aks-admin-nonprod
      # Additional Azure-RBAC-for-K8s role assignments on every AKS in env.
      # These do NOT bypass K8s RBAC; they grant built-in K8s roles via AAD.
      rbac_cluster_admins: [<group-object-id>] # grp-platform-admin-nonprod
      rbac_readers: [<group-object-id>] # grp-platform-reader-nonprod (optional)
    grafana:
      admins: [<group-object-id>] # grp-grafana-nonprod-admins
      editors: [<group-object-id>] # grp-grafana-nonprod-editors
    action_group:
      receivers:
        slack: { webhook_url_kv_secret: slack-webhook-nonprod }
  prod:
    subscription_id: <sub-fleet-prod>
    aks:
      admin_groups: [<group-object-id>] # grp-aks-admin-prod (very small)
      rbac_cluster_admins: [<group-object-id>] # grp-platform-admin-prod
      rbac_readers: [<group-object-id>] # grp-platform-reader-prod
    grafana:
      admins: [<group-object-id>] # grp-grafana-prod-admins
      editors: [<group-object-id>] # grp-grafana-prod-editors
    action_group:
      receivers:
        pagerduty: { integration_key_kv_secret: pagerduty-prod }
        slack: { webhook_url_kv_secret: slack-webhook-prod }
  mgmt:
    subscription_id: <sub-fleet-mgmt>
    # Location for mgmt-only resources that are not bound to a
    # cluster env-region (fleet resource groups, fleet-meta UAMI,
    # tenant-scope role assignments, fleet-ACR). Cluster-bearing
    # env-regions take their location from the
    # `networking.envs.<env>.regions.<region>` key.
    location: eastus
    aks:
      admin_groups: [<group-object-id>] # grp-aks-admin-mgmt
      rbac_cluster_admins: [<group-object-id>] # grp-platform-admin (platform SRE)
      rbac_readers: []
    grafana:
      admins: [<group-object-id>] # grp-grafana-mgmt-admins (platform team)
      editors: []
    action_group:
      receivers:
        pagerduty: { integration_key_kv_secret: pagerduty-platform }

dns:
  fleet_root: int.acme.example # opinionated root; every zone is a child of this
  # Zone FQDN for each cluster is derived automatically:
  #   <cluster.name>.<cluster.region>.<cluster.env>.<fleet_root>
  # e.g. aks-nonprod-01.eastus.nonprod.int.acme.example
  resource_group_pattern: rg-dns-{env} # env-scoped RG for all cluster zones in that env (optional)
```

### 3.2 DNS hierarchy (opinionated, derived)

- **Single source of truth**: `dns.fleet_root` in `_fleet.yaml`. No
  cluster may override the root.
- **Zone FQDN is derived from directory path**:

  ```
  clusters/<env>/<region>/<name>/cluster.yaml
                    │        │       │
                    │        │       └── cluster name
                    │        └────────── region
                    └─────────────────── env

  → zone FQDN = <name>.<region>.<env>.<dns.fleet_root>
  ```

- **Resource group** for every cluster's private zone follows
  `dns.resource_group_pattern` with `{env}` substitution (default
  `rg-dns-{env}`). Operators can override on a single cluster via
  `platform.dns.resource_group` in `cluster.yaml`, but no other DNS
  fields are settable.
- **VNet linking**: derived, not BYO. Per PLAN §3.4, every cluster's
  private DNS zone is linked to its env-region VNet and the mgmt
  env-region VNet in the same region (mgmt clusters collapse to a
  single link) — operator-visible VNet selection is gone. Stage 1
  creates one `virtualNetworkLinks` child resource per id in that
  derived list.
- **Naming of zone-link resources** is derived:
  `link-<last-segment-of-vnet-resource-id>`.
- **External-DNS config** (rendered into platform-gitops values by a
  per-cluster ApplicationSet parameter):
  - `--domain-filter=<zone-fqdn>`
  - `--txt-owner-id=<cluster.name>`
  - provider identity = this cluster's external-dns UAMI (from
    `platform-identity` secret).
- **Blast radius**: RBAC role `Private DNS Zone Contributor` is
  assigned **at the zone's resource id**, not the resource group.
  External-dns in one cluster cannot read, write, or discover any
  other zone — including sibling clusters in the same env or region.
- **Parent zones** (`<region>.<env>.<fleet_root>` and above) are not
  created by this repo. Azure Private DNS resolves via the most
  specific VNet-linked zone, so clients in the hub VNet that has the
  cluster's zone linked resolve `*.<cluster-zone>` directly. If
  cross-cluster resolution within an env is required later, a
  dedicated env-level zone can be added out-of-band and linked to the
  hub; it does not require delegation from/to any cluster zone.
- **Terraform outputs** per cluster: `dns_zone_fqdn`,
  `dns_zone_resource_id`, `ingress_domain` (alias of `dns_zone_fqdn`)
  — consumed by ApplicationSet parameters so platform-gitops never
  hard-codes DNS names.

### 3.3 Derivation rules (config-loader responsibilities)

`terraform/config-loader/load.sh` is responsible for deriving computed
values from the directory path plus fleet config and merging them into
the per-cluster tfvars.json before Terraform ever sees it:

| Computed value            | Formula                                                                                            |
| ------------------------- | -------------------------------------------------------------------------------------------------- |
| `cluster.name`            | final directory segment of the cluster path                                                        |
| `cluster.env`             | 1st segment under `clusters/`                                                                      |
| `cluster.region`          | 2nd segment under `clusters/`                                                                      |
| `dns.zone_fqdn`           | `<cluster.name>.<cluster.region>.<cluster.env>.<fleet.dns.fleet_root>`                             |
| `dns.zone_rg`             | `platform.dns.resource_group` override else `dns.resource_group_pattern` with `{env}` substituted  |
| `keyvault.name`           | `platform.keyvault.name` override else `kv-<cluster.name>` (truncated to 24 chars per Azure limit) |
| `keyvault.resource_group` | `platform.keyvault.resource_group` override else `<cluster.resource_group>`                        |
| `acr.login_server`        | `<fleet.acr.name>.azurecr.io` (or Stage 0 output if overridden)                                    |
| `cluster.domain`          | `<dns.zone_fqdn>` (used for `argocd.<domain>`, `kargo.<domain>`)                                   |
| `networking.vnet_name`    | `vnet-<fleet.name>-<env>-<region>` (uniform across all envs incl. mgmt)                            |
| `networking.net_rg_name`  | `rg-net-<env>-<region>`                                                                             |
| `networking.snet_pe_fleet.cidr` | first `/26` of the mgmt-env-region VNet's address_space (`snet-pe-fleet`; houses CI-plane PEs — tfstate SA, fleet KV, fleet ACR). Present only on mgmt VNets; owned by `bootstrap/fleet`. |
| `networking.snet_runners.cidr` | second derived slice of the mgmt-env-region VNet's address_space sized for an ACA Container App Environment (workload profile `/23`; `snet-runners`, ACA-delegated). Present only on mgmt VNets; owned by `bootstrap/fleet`. |
| `networking.snet_pe_env.cidr` | first `/26` of the cluster-workload zone within the env-region VNet (`snet-pe-env`; houses env Grafana PE and cluster-PE workloads — including mgmt cluster KV PE on mgmt VNets). Present on every env VNet; owned by `bootstrap/environment`. |
| `networking.snet_aks_api.cidr` | i-th `/28` of the API pool, where i = `networking.subnet_slot`. Parent VNet = the cluster's env-region VNet. |
| `networking.snet_aks_nodes.cidr` | i-th `/25` of the nodes pool, where i = `networking.subnet_slot`. Parent VNet = the cluster's env-region VNet. |
| `networking.pod_cidr`     | `100.64.0.0/16` (fleet-wide constant, hard-coded in `modules/aks-cluster/main.tf`; see §3.4 *Pod CIDR (shared, fleet-wide)*) |
| `networking.peering_name.spoke_to_mgmt` | `peer-<env>-<region>-to-mgmt-<mgmt-region>` (authored from env state for every non-mgmt env-region)  |
| `networking.peering_name.mgmt_to_spoke` | `peer-mgmt-<mgmt-region>-to-<env>-<region>` (authored from env state when the env-region sets `create_reverse_peering = true`) |
| `networking.node_asg_name`      | `asg-nodes-<env>-<region>`. One ASG per env-region VNet (incl. mgmt), owned by `bootstrap/environment`, shared by all clusters in the VNet. |

Operators cannot override derived values except for `dns.zone_rg`.
This keeps naming consistent and prevents drift between directory
structure and Azure-resource names.

### 3.4 Networking topology

> **Scope.** This section is the source of truth for VNet ownership,
> peering, subnet layout, and the `subnet_slot` contract. The
> ownership split is uniform across every env (including `mgmt`):
> `bootstrap/fleet` owns fleet-plane subnets it needs for its own
> resources (CI-plane PEs, fleet-KV PE, fleet-ACR PE, and the
> ACA-delegated Container App Environment that hosts the runner pool)
> — all in the mgmt env-region VNet only. `bootstrap/environment`
> owns the env-region VNets themselves plus every cluster-workload
> subnet (api pool, nodes pool, env-PE, node ASG, route table) on
> every env-region VNet uniformly, mgmt included. Stage 1 adds
> per-cluster subnets + AKS ASG attachment. Derivation parity is
> enforced across `docs/naming.md`, `config-loader/load.sh`, and
> `modules/fleet-identity/`.

**UDR for AKS egress.** `modules/aks-cluster` sets
`network_profile.outbound_type = userDefinedRouting`. The hub-firewall
next-hop IP that both AKS api-server and node traffic route
`0.0.0.0/0` at is carried as `egress_next_hop_ip` on each env-region
entry in `_fleet.yaml`
(`networking.envs.<env>.regions.<region>.egress_next_hop_ip`);
adopters fill this in with their hub firewall / NVA private IP before
creating a cluster in that region. `bootstrap/environment` always
authors the `rt-aks-<env>-<region>` route table shell on every
env-region VNet (mgmt included); the `0.0.0.0/0` route entry is only
created when `egress_next_hop_ip` is non-null. The route table is
associated with **both** the nodes subnet and the api-server delegated
subnet — AKS api-server VNet integration egresses through the same
next-hop as nodes. Stage 1 fails fast when `egress_next_hop_ip` is
null for a region that hosts clusters.

**Service CIDR reservation.** `modules/aks-cluster` hard-codes
`network_profile.service_cidr = 100.127.0.0/16` with
`dns_service_ip = 100.127.0.10`, reserving the top `/16` of CGNAT
(`100.64.0.0/10`) for the in-cluster virtual ClusterIP pool. Service
CIDRs are DNATed inside the node's dataplane and never appear on any
wire, but they MUST NOT overlap any address reachable from pods —
otherwise pods trying to reach a real VM at a service-CIDR address get
DNATed to a random pod. Placing the service CIDR in CGNAT guarantees
disjointness from any adopter VNet (RFC-1918 required by
`init/variables.tf`). The same value is shared across every cluster
in the fleet, which is safe because ClusterIPs are cluster-local.

**Tiers.**

| Tier | VNet                                   | Owner                                                  | Peerings                                                                                                                           |
| ---- | -------------------------------------- | ------------------------------------------------------ | ---------------------------------------------------------------------------------------------------------------------------------- |
| Hub  | adopter-owned, BYO (per env-region)    | adopter (outside repo)                                 | every env-region VNet with a non-null `hub_network_resource_id` hub-peers to that hub via the sub-vending module (null = opt out) |
| Env  | `vnet-<fleet.name>-<env>-<region>`     | `bootstrap/environment` (VNet + cluster-workload subnets); `bootstrap/fleet` (fleet-plane subnets on mgmt VNets only) | ↔ hub (via sub-vending); full mesh intra-env (sub-vending, per-env invocation); ↔ mgmt (per env-region, both halves in env state)       |

- One env-region VNet per `networking.envs.<env>.regions.<region>`
  entry. This scales to any number of environments subject to
  CIDR-capacity availability in the fleet supernet; the worked
  example throughout the repo uses `{mgmt, nonprod, prod}`. Azure
  VNets are regional, so adding a region means adding a
  `regions.<region>` key and re-running `env-bootstrap.yaml` for
  that env.
- **Mgmt is an env like any other**, not a distinct tier: it has
  env-region VNets authored by `bootstrap/environment`, its own
  cluster-workload subnets, its own env-PE subnet (for the mgmt
  cluster KV and any other mgmt-cluster PEs), and its own node
  ASG. It differs only in that `bootstrap/fleet` additionally
  reserves a fleet-plane zone on the mgmt VNet for the CI-plane PEs
  and the runner-pool Container App Environment. Mgmt env-regions
  carry their own `hub_network_resource_id` (typically pointing at
  another env's hub, since mgmt usually shares a non-prod or prod
  hub rather than running its own) and hub-peer via the sub-vending
  module on the same code path as every other env.
- Peerings between non-mgmt envs (e.g. prod↔nonprod) are
  intentionally **not** authored. The sub-vending
  `mesh_peering_enabled` flag is scoped to a single invocation, so
  `bootstrap/environment` is called once per env — different envs
  never appear in the same mesh call. Cross-env connectivity, when
  required, flows through the mgmt VNet via the mgmt↔spoke
  peerings.

**Modules (referenced by registry; not vendored).**

- `Azure/avm-ptn-alz-sub-vending/azure` (`~> X.Y` to be pinned at
  implementation time; azapi-only, `enable_telemetry = false`). Used
  by `bootstrap/environment` for every env (including mgmt) with
  `N = len(regions)`, `mesh_peering_enabled = true` per-env (so
  intra-env regions mesh-peer), and per-VNet `hub_peering_enabled
  = true` against the hub selected for that (env, region).
- `Azure/avm-res-network-virtualnetwork/azurerm//modules/peering`
  (`~> X.Y`; azapi-only). Called from `bootstrap/environment` once
  per env-region with `create_reverse_peering =
  local.region.create_reverse_peering` (default true), so both
  halves of every mgmt↔spoke peering land in the env state when the
  adopter permits it. No repo-local peering helper is introduced.

**CIDR layout per env-region VNet — two-pool cluster design with
reserved fleet-plane zone on mgmt (`/20` envelope).**

Every env-region VNet uses the same two-pool layout for cluster
workloads:

- `snet-aks-api-<slot>` — **exactly `/28`** (required by AKS
  API-server VNet integration; subnet is delegated to
  `Microsoft.ContainerService/managedClusters` and must be empty /
  unshared).
- `snet-aks-nodes-<slot>` — `/25` (default; sized for Azure CNI
  **Overlay** with Cilium, where pod IPs come from
  `networking.pod_cidr` and never consume node-subnet addresses, so
  `/25` = 128 addrs covers nodes + ILBs comfortably).

Address space is ordered so that cluster-workload subnets owned by
`bootstrap/environment` occupy the low end of the VNet — uniform
across all envs including mgmt — and the fleet-plane zone owned by
`bootstrap/fleet` occupies the high end of the mgmt VNet only:

```
# Non-mgmt env-region VNet (e.g. nonprod/eastus, prod/eastus):
10.x0.0.0/20      VNet address_space
│
├── 10.x0.0.0/24     cluster reserved zone (first /24; bootstrap/environment)
│   └── 10.x0.0.0/26    snet-pe-env      (env Grafana PE + per-cluster PEs)
│
├── 10.x0.1.0/24     API pool → 16 × /28 (bootstrap/environment; Stage 1 carves)
│   └── ...             snet-aks-api-<slot 0..15>
│
└── 10.x0.2.0/21     NODES pool → 2 × /25 per /24 (bootstrap/environment; Stage 1 carves)
    └── ...             snet-aks-nodes-<slot 0..>

# Mgmt env-region VNet (e.g. mgmt/eastus):
10.x0.0.0/20      VNet address_space
│
├── 10.x0.0.0/24     cluster reserved zone (first /24; bootstrap/environment)
│   └── 10.x0.0.0/26    snet-pe-env      (mgmt-cluster KV PE + other mgmt-cluster PEs)
│
├── 10.x0.1.0/24     API pool (bootstrap/environment; capped at mgmt cluster count)
│   └── ...             snet-aks-api-<slot 0..N-1>
│
├── 10.x0.2.0/24     NODES pool (bootstrap/environment; sized for mgmt cluster count)
│   └── ...             snet-aks-nodes-<slot 0..N-1>
│
└── 10.x0.8.0/21     fleet-plane zone (bootstrap/fleet; second half of VNet)
    ├── 10.x0.8.0/23    snet-runners     (ACA-delegated Container App Environment)
    └── 10.x0.10.0/26   snet-pe-fleet    (tfstate SA, fleet KV, fleet ACR PEs)
```

Capacity per env-region VNet `/N`:

- **Non-mgmt env-regions** follow
  `capacity = min(16, 2 * (2^(24-N) - 2))`:
  - `/20` → `min(16, 26)` = **16 clusters**  (api pool is the bottleneck)
  - `/21` → `min(16, 10)` = **10 clusters**
  - `/22` → `min(16, 2)`  = **2 clusters**
- **Mgmt env-regions** are intentionally capped at a small cluster
  count (**2–4 clusters** at `/20`) so the fleet-plane zone has
  generous room to grow. The ACA Container App Environment alone
  requires a `/23` for the workload-profile SKU used by the runner
  pool; CI-plane PE counts grow with fleet size (tfstate SA, fleet
  KV, fleet ACR, plus future additions). Mgmt is not a workload
  density target — it hosts the mgmt cluster(s) that run Kargo /
  Argo control planes, not tenant workloads.

**Pool derivation (given env-region VNet address_space `A = <ip>/N`).**

```
reserved   = cidrsubnet(A, 24-N, 0)  # first /24, env-PE lives here
api_pool   = cidrsubnet(A, 24-N, 1)  # second /24, 16 × /28
# nodes pool = /24s at index 2..K of A, where K is the non-mgmt
# envelope end or the mgmt cluster-zone end depending on env.

snet_aks_api(i)   = cidrsubnet(api_pool, 4, i)              # i ∈ [0, cap)
snet_aks_nodes(i) = let base = cidrsubnet(A, 24-N, 2 + (i / 2))
                    in  cidrsubnet(base, 1, i % 2)          # i ∈ [0, 2*(K-1))

# Mgmt-only fleet-plane zone (second half of A):
fleet_zone        = cidrsubnet(A, 1, 1)                     # upper /21 of /20
snet_runners      = cidrsubnet(fleet_zone, 24-(N+1)-2, 0)   # /23 ACA workload
snet_pe_fleet     = cidrsubnet(fleet_zone, 6, 8)            # /26 CI-plane PEs
```

`subnet_slot: i` is the single per-cluster index consumed by both
the api and nodes formulas — api and nodes subnets always share
the same index, so operators reason about "cluster 3" not
"cluster 3 api + cluster 5 nodes."

Design notes:

- Azure CNI **Overlay + Cilium** is the fleet CNI. Pod IPs come
  from `networking.pod_cidr` (a separate non-routable space per
  cluster), so the nodes subnet only holds nodes + internal load
  balancers. `/25` is comfortably sized; shrinking to `/26` would
  double nodes-pool capacity if api-pool growth ever lands
  upstream, but the api `/28` delegation is AKS-fixed.
- The cluster-zone two-pool layout has zero address waste within
  the zone: every `/28` in the api pool and every `/25` in the
  nodes pool is usable.
- If a third per-cluster subnet is ever needed (e.g. moving off
  CNI Overlay to a pod-subnet CNI), a third pool is added under
  the same design — no rearrangement of existing pools. Non-trivial
  but bounded change.

**`subnet_slot` contract.**

- Declared **required** in every `cluster.yaml` under
  `networking.subnet_slot: <int>`. No default.
- `validate.yaml` PR-check enforces:
  1. present on every cluster.yaml;
  2. integer in `[0, capacity-1]` where `capacity` is computed from
     the env+region VNet's address_space by the two-pool formula
     above (16 for a `/20`);
  3. unique across all clusters sharing an (env, region);
  4. **immutable once set** — changing it in-place re-plans
     subnet replacement, which destroys/recreates the AKS cluster
     (cluster.yaml diff in `git` against `main` blocks the PR).
- Operators pick slots at cluster-creation time. The scaffolded
  `clusters/_template/cluster.yaml` carries `subnet_slot: 0` with a
  comment pointing at this section.

**Single-PR new-cluster flow.**

1. Operator `cp -r clusters/_template clusters/<env>/<region>/<name>/`,
   edits `cluster.yaml` (including `subnet_slot`).
2. Opens PR → `validate.yaml` runs the `subnet_slot` check and
   normal schema lint.
3. On merge, `tf-apply.yaml` runs Stage 1 (creates the `/28` api
   subnet in the env VNet's API pool and the `/25` nodes subnet in
   the nodes pool via azapi, attaches the AKS node pool to the
   env-region node ASG, creates the AKS cluster) and Stage 2
   (ArgoCD bootstrap) in one matrix leg. No re-run of
   `bootstrap/environment` is required.

**Peering ownership.**

- **Hub peerings** are emitted by the sub-vending module (per-VNet
  `hub_peering_enabled`) against
  `networking.envs.<env>.regions.<region>.hub_network_resource_id`.
  Non-null → `hub_peering_enabled = true` with that id as the target;
  null → `hub_peering_enabled = false` (env-region opts out of hub
  peering). The same code path applies uniformly to every env
  including mgmt — there is no mgmt-specific hub-selection rule.
- **Intra-env mesh peerings** are emitted by the sub-vending module
  (`mesh_peering_enabled = true`) so all regions within a single env
  peer to each other.
- **Mgmt↔env peerings live in the env state** (`bootstrap/environment`,
  authored on the non-mgmt side for non-mgmt envs; authored implicitly
  for mgmt as the reverse half of those peerings). For every non-mgmt
  env-region, `bootstrap/environment` iterates
  `networking.envs.mgmt.regions.*` and calls the peering AVM module
  once per mgmt env-region — resolving the mgmt target VNet by
  same-region match if one exists, otherwise the first mgmt region.
  Each call uses `create_reverse_peering =
  networking.envs.<env>.regions.<region>.create_reverse_peering`
  (default true). When true, both halves land in the env state and
  are destroyed atomically if the spoke VNet is retired; when false,
  only the spoke→mgmt half is authored and the mgmt→spoke half is
  expected to exist out-of-band.
- `bootstrap/fleet` grants the `fleet-meta` UAMI `Network Contributor`
  scoped to every mgmt env-region VNet resource id so
  `bootstrap/environment` can write the mgmt→spoke half under the
  `fleet-meta` identity when `create_reverse_peering = true`.

**Per-cluster private DNS zone links.**

- Derived (not BYO): `[cluster's env-region VNet, mgmt env-region
  VNet for the cluster's region]` for every cluster. Mgmt clusters
  collapse to a single-VNet link (their env-region VNet *is* the
  mgmt VNet).
- Stage 1 creates the `virtualNetworkLinks` children on the
  cluster's zone — two links for non-mgmt clusters, one link for
  mgmt clusters. VNet ids come from the env-scope repo variable
  `<ENV>_<REGION>_VNET_RESOURCE_ID`.

**Application Security Groups for AKS nodes.**

- One ASG per env-region VNet named `asg-nodes-<env>-<region>`,
  owned by `bootstrap/environment` uniformly across all envs
  including mgmt.
- Acts as the symbolic source group for rules on the VNet's PE-subnet
  NSGs (e.g., allow 443 from nodes to PEs in the VNet). On mgmt VNets
  the same ASG is referenced by rules on `nsg-pe-env` (cluster-PE
  subnet) and, where applicable, by cross-subnet rules on
  `nsg-pe-fleet` (fleet-plane PE subnet owned by `bootstrap/fleet`).
- Stage 1 attaches each AKS cluster's node pool to its env-region
  node ASG via the AKS `networkProfile.applicationSecurityGroups`
  input on the AVM module (subject to the pinned AKS API version
  exposing that field on agent pools — **confirm at implementation
  time**).
- **Fallback** if the pinned AKS API does not support agent-pool
  ASG attachment: Stage 1 writes per-cluster NSG rules into the
  relevant `nsg-pe-*` directly. `bootstrap/environment`
  pre-grants the `fleet-<env>` UAMI scoped `Network Contributor`
  on the env-region NSGs so the cross-stage write succeeds.

**Repo variables published (extends §4 Stage 0 / §4 `bootstrap/environment`).**

| Variable                              | Shape                                        | Published by            | Consumed by                                                                                                          |
| ------------------------------------- | -------------------------------------------- | ----------------------- | -------------------------------------------------------------------------------------------------------------------- |
| `<ENV>_<REGION>_VNET_RESOURCE_ID`     | scalar ARM id                                | `bootstrap/environment` | Stage 1 (subnet parent, DNS zone link); env observability wiring; cross-env spoke reverse-peering target for mgmt VNets |
| `<ENV>_<REGION>_NODE_ASG_RESOURCE_ID` | scalar ARM id                                | `bootstrap/environment` | Stage 1 (AKS node-pool ASG attachment, or NSG rule author)                                                           |
| `MGMT_VNET_RESOURCE_IDS`              | `jsonencode({ <region> = <vnet-resource-id> })` | `bootstrap/fleet`       | `bootstrap/environment` (env=mgmt branch carves cluster-workload subnets as azapi children of these VNets; non-mgmt envs resolve mgmt↔env reverse-peering targets by iterating this map with same-region-else-first fallback); Stage 1 (mgmt DNS zone VNet link in the cluster's region) |
| `MGMT_PE_FLEET_SUBNET_IDS`            | `jsonencode({ <region> = <subnet-resource-id> })` | `bootstrap/fleet`    | (consumed inside `bootstrap/fleet` for tfstate SA / fleet KV / fleet ACR PEs; published for observability/diagnostics) |
| `MGMT_RUNNERS_SUBNET_IDS`             | `jsonencode({ <region> = <subnet-resource-id> })` | `bootstrap/fleet`    | (consumed inside `bootstrap/fleet` for the ACA runner-pool Container App Environment; published for diagnostics)       |

Non-mgmt env-region variables are scalar because each
`<env>-bootstrap` workflow run targets a single env, and GitHub
Actions variable names are the natural fan-out axis. Mgmt fleet-plane
variables are published as JSON-encoded `{region: id}` maps because
(a) `bootstrap/fleet` knows every mgmt region at apply time, so a
single publish is atomic, (b) downstream workflows index by region
via `fromJSON(vars.MGMT_*)[cluster.region]`, and (c) the map shape
keeps the variable surface constant regardless of mgmt-region count.
Stage 1 resolves a cluster's parent VNet and node ASG from
`<cluster.env>_<cluster.region>_{VNET_RESOURCE_ID,NODE_ASG_RESOURCE_ID}`
(scalar); mgmt clusters use the same lookup, and the mgmt env-region
VNet is ordinary env-region state. The `MGMT_*` fleet-plane map
variables exist only for the fleet-plane subnets `bootstrap/fleet`
itself owns on the mgmt VNets.

**Pod CIDR (shared, fleet-wide).**

Pod IPs come from a single fleet-wide CGNAT block, `100.64.0.0/16`,
hard-coded in `modules/aks-cluster/main.tf`. Every cluster in the
fleet uses the same pod CIDR. This is safe because Azure CNI
**Overlay** + Cilium encapsulates pod-to-pod traffic on the node
and SNATs egress to the node IP — pod IPs are never visible on the
wire outside the node and never routed at the VNet fabric. Every
observability surface that reports pod IPs (Log Analytics, managed
Prometheus, kube-state-metrics) carries `_ResourceId` / cluster name
in the same row, so cross-cluster disambiguation by pod IP is not
required.

The service CIDR is likewise fleet-wide: `100.127.0.0/16`, hard-coded
in the same module with `dns_service_ip = 100.127.0.10`. It is
disjoint from the shared pod `/16` by construction (top `/16` of the
same `100.64.0.0/10` CGNAT block). See the *Service CIDR reservation*
paragraph earlier in this section for rationale.

Re-introducing per-cluster pod CIDRs is a bounded change if
ClusterMesh or any cross-cluster pod routing is ever adopted: restore
the `pod_cidr` variable in `modules/aks-cluster`, re-derive it in
`config-loader/load.sh` from a per-env-region slot, and thread it
through Stage 1.

**Stage 1 AKS module passthrough (`cluster.aks.*`).**

Operators tune AKS behaviour via a **curated typed** surface declared
in `terraform/modules/aks-cluster/variables.tf`. Each `cluster.aks.<key>`
maps 1:1 to an input on the wrapped AVM module
(`Azure/avm-res-containerservice-managedcluster/azurerm`). There is
intentionally **no** freeform `extra` / `passthrough` map: adding a
new knob means adding a variable to `modules/aks-cluster/variables.tf`
plus a one-line assignment in its `main.tf`, keeping the contract
between cluster YAML and AKS ARM inputs explicit and reviewable.

Keys exposed at initial landing (expand commit-by-commit as needs
arise): `kubernetes_version`, `sku_tier`, `auto_scaler_profile`,
`auto_upgrade_profile`. The following are **hard-coded** inside
`modules/aks-cluster` per this section's security/auth contract and
are not overridable per cluster: `disable_local_accounts = true`,
`aad_profile.managed = true`, `enable_azure_rbac = true`,
`oidc_issuer_profile.enabled = true`,
`security_profile.workload_identity.enabled = true`,
`api_server_access_profile.{enable_private_cluster, enable_vnet_integration} = true`,
`network_profile.{network_plugin=azure, network_plugin_mode=overlay, network_dataplane=cilium, network_policy=cilium, outbound_type=userDefinedRouting, load_balancer_sku=standard}`.

**Provider carveout.** The AVM AKS module authors the managed
cluster via `azapi_resource` but ships `azurerm_management_lock`,
`azurerm_role_assignment`, and `azurerm_monitor_diagnostic_setting`
as optional features. Stage 1 therefore declares both `azurerm ~> 4.46`
and `random ~> 3.5` alongside `azapi ~> 2.9` in `providers.tf`. This
is an intentional carveout from the azapi-only invariant in §2; the
RBAC follow-up uses `role_assignments` and the observability phase
uses `diagnostic_settings`, so the extra providers are load-bearing
not worked-around.

---

## 4. Terraform stages

### Stage -1 — Bootstrap (`terraform/bootstrap/`)

Three TF roots, each run rarely. Bootstrap exists to create the
identities and GitHub scaffolding that CI-run stages depend on.

All three roots compose the vendored `terraform/modules/github-repo`
module (fork of `terraform-github-repository-and-content`; see
`terraform/modules/github-repo/VENDORING.md`). `bootstrap/fleet`
owns the fleet repo, both its GH Actions environments (`fleet-stage0`,
`fleet-meta`), their UAMIs + federated credentials, env-scoped RBAC,
and the `main`-branch protection ruleset via a single
`module "fleet_repo"` call. `bootstrap/environment` calls the
`modules/github-repo/modules/environment` submodule directly (the
fleet repo itself is already owned by `bootstrap/fleet`) and
preserves the FIC name `gh-fleet-<env>` via the `identity.fic_name`
override. `bootstrap/team` uses `template = {...}` + a managed
`.github/CODEOWNERS` file via `files`, plus a matching `main`-branch
ruleset. OIDC subject claims use ID-based keys (`repository_owner_id`,
`repository_id`, `environment`) on both sides — immutable, so
org/repo renames cannot silently invalidate federated credentials.
Env variables that reference a module's own UAMI output
(`AZURE_CLIENT_ID` etc.) are created at the callsite as separate
`github_actions_environment_variable` resources, not via the module's
`variables` input, to avoid a module-to-child-output cycle.

The fleet Key Vault is owned by `bootstrap/fleet` (Stage -1),
co-located with the tfstate SA and runner pool. The Stage -1 runner
pool's Container App Job holds a Key Vault reference to
`fleet-runners-app-pem`, which ACA validates (via the attached UAMI)
at PUT time — requiring the KV, the secret path, and the
`Key Vault Secrets User` role assignment to exist in the same apply
graph as the runner module. The vault is strictly private
(`publicNetworkAccess = Disabled`, `networkAcls.defaultAction =
Deny`, `bypass = None`) with a PE on the derived `snet-pe-fleet`
subnet registering into the central
`privatelink.vaultcore.azure.net` zone. Stage 0 holds
`Key Vault Secrets Officer` on the vault (for rotating
`argocd-oidc-client-secret` and seeding GH App PEMs) and references
the KV by a derived id reconstructed from `_fleet.yaml`. The
`uami-fleet-runners` identity and its `Key Vault Secrets User` role
assignment on the vault also live in `bootstrap/fleet` (same apply
graph as the runner module's KV reference). PEM seeding of
`fleet-runners-app-pem` is done by the post-bootstrap
`init-gh-apps.sh` helper, which must run from a host with data-plane
reach to the KV.

#### `bootstrap/fleet/` — human-run, one-time per repo

Run locally with tenant-admin + subscription-owner credentials. Uses
local state (committed lockfile, not state).

##### Prerequisites

All of the following must be true on the operator's workstation
*before* `terraform apply` is invoked. The adoption helper scripts
(§16.3, §16.4) check most of these and fail fast with actionable
messages; the rest must be arranged out-of-band by the adopter org.

**Azure**

- Authenticated `az login` session in the tenant identified by
  `_fleet.yaml.fleet.tenant_id`. Both `azapi` and `azuread`
  providers run with `use_cli = true`; no service-principal env
  vars are read.
- Tenant role: **Privileged Role Administrator** (or Global
  Administrator) — required to grant the Entra
  `Application Administrator` directory role to the `fleet-stage0`
  and `fleet-meta` UAMIs. Without it the apply errors at the
  `azuread_directory_role_assignment` step.
- Subscription role on `_fleet.yaml.acr.subscription_id` (the
  fleet-shared subscription): **Owner** (or Contributor + User
  Access Administrator). Used to create resource groups, the
  tfstate storage account + container, the bootstrap UAMIs and
  their FICs, and `roleAssignments` on the shared RG and tfstate
  container.
- Resource provider registrations on the shared subscription:
  `Microsoft.Storage`, `Microsoft.Resources`,
  `Microsoft.ManagedIdentity`, `Microsoft.Authorization`,
  `Microsoft.ContainerRegistry`. Not enforced in code today; an
  RP-not-registered error is the most common first-apply failure.
- Names that must be free (or correspond to overrides in
  `_fleet.yaml`): storage account `st<fleet.name>tfstate`
  (≤ 24 chars; collides on the global namespace), and resource
  groups `rg-fleet-tfstate` and `rg-fleet-shared` in the shared
  subscription must not pre-exist with conflicting state.

**Networking (Stage -1 runner pool + private tfstate SA)**

- Pre-existing VNet in `rg-fleet-shared` (or in the hub
  connectivity subscription, peered to the fleet subscription)
  with two subnets: one delegated to `Microsoft.App/environments`
  for the runner pool (`snet-runners` by convention), and one for
  private endpoints (`snet-pe-fleet`). The runner subnet must
  carry a UDR routing egress through the hub firewall; the module
  callsite sets `nat_gateway_creation_enabled = false` and
  `public_ip_creation_enabled = false`, so there is no runner-
  local NAT or public IP.
- Central `privatelink.blob.core.windows.net` private DNS zone in
  the hub connectivity subscription (shared across the tenant).
  Referenced by resource id from
  `_fleet.yaml.networking.tfstate.private_endpoint.private_dns_zone_id`.
- Central `privatelink.azurecr.io` private DNS zone in the same
  hub/connectivity sub (shared with every other ACR PE in the
  tenant). Referenced by resource id from
  `_fleet.yaml.networking.runner.container_registry_private_dns_zone_id`.
  The runner-pool module is invoked with
  `container_registry_private_dns_zone_creation_enabled = false`
  and only registers A-records into this zone via the PE's DNS
  zone group — no zone is ever created by this repo.
- Tenant-scope role: **`Private DNS Zone Contributor`** on *both*
  central zones (blob + ACR) — for the operator on first apply,
  and for the `fleet-stage0` UAMI (for subsequent re-runs).
- VNet-reachable workstation (jump host / Azure Bastion / VPN)
  for every re-run of `bootstrap/fleet` after the first apply;
  the tfstate storage account is PE-only once Stage -1 has run.
- One-time first-apply escape hatch:
  `var.allow_public_state_during_bootstrap = true` leaves the
  tfstate SA's public endpoint Enabled (with `networkAcls.defaultAction
  = "Deny"` still in place) long enough to seed the PE + DNS zone
  group. The flag must be flipped back to `false` on the second
  apply. No long-lived public exposure.

**GitHub**

- Fleet repo already exists on github.com — the adopter clicks
  **Use this template** in the template repo's web UI; the new
  repo is then referenced by `bootstrap/fleet` via an `import`
  block, never created by Terraform.
- `GITHUB_TOKEN` exported in the shell, with classic-PAT scopes
  `repo:admin` + `admin:org` (the latter only if `github_org` is
  an organization). Used by the `integrations/github` provider
  for repo settings, branch protection, environments, environment
  variables, and creating the team-repo template repo.
- Both **GitHub Apps** (`fleet-meta`, `stage0-publisher`) created
  and installed on the fleet repo, with their app-id, client-id,
  PEM, and webhook secret captured. This is **not**
  `terraform apply`-able from the platform's API — the GitHub App
  Manifest flow requires a one-time browser handshake.
  **Future (once §16.4 lands):** the adopter runs
  `./init-gh-apps.sh` (repo root, next to `init-fleet.sh`), which
  automates everything *except* the click-to-create step, and
  writes credentials to `./.gh-apps.auto.tfvars` for **Stage 0**
  to consume (not `bootstrap/fleet`).
  **Today (Phase 1):** GH Apps are **not required** to
  `terraform apply` `bootstrap/fleet` — this stage does not
  consume App credentials. Adopters who want env/team-bootstrap
  workflows to function end-to-end must create the Apps manually
  via *Organization settings → Developer settings → GitHub Apps*
  with the permissions listed in §4 Stage 0; Stage 0 does not yet
  declare input variables for them, so the credentials currently
  have no TF consumer (they're supplied directly to workflow
  secrets by the operator).
- Repo `<github_org>/<team_template_repo>` (default
  `team-repo-template`) must **not** pre-exist; it is created
  fresh by `bootstrap/fleet` with `prevent_destroy = true`.

**Local tooling**

- `terraform` ≥ 1.9 (pessimistic `~> 1.9`).
- `az` CLI (any recent version).
- `gh` CLI authenticated to the same GitHub account that holds
  `GITHUB_TOKEN` — required by the GH App helper script (§16.4)
  for the manifest exchange and for installing the resulting
  Apps on the fleet repo.
- `git`, `python3`, `bash`. `yq` is not required by this stage
  (only by the runtime config-loader, §3.3).

**Repo state**

- `init-fleet.sh` has been run successfully (the
  `.fleet-initialized` marker is present and committed). Without
  this, `clusters/_fleet.yaml` does not exist and
  `bootstrap/fleet` fails immediately at
  `yamldecode(file(...))`.
- `clusters/_fleet.yaml` has every adopter-supplied field
  populated (no `__PROMPT__` sentinels remain; `<...>` placeholder
  fields under `envs.*` may remain empty until
  `bootstrap/environment` runs for that env).
- **Future (once §16.4 lands):** `init-gh-apps.sh` (at the repo
  root) has been run successfully and its outputs are available
  as `./.gh-apps.auto.tfvars` for **Stage 0** — see §16.4 for the
  exact variable names. The fleet Key Vault is created by
  `bootstrap/fleet`; **Stage 0 seeds the GH App PEMs + webhook
  secrets into it** (Stage 0 holds `Key Vault Secrets Officer` on
  the vault). `bootstrap/fleet` does not write or manage the GitHub
  App credentials.
  **Today (Phase 1):** not a prerequisite — `bootstrap/fleet` has
  no GH App input variables and Stage 0 has not yet added the
  §16.4 GH App input variables / KV-seed resources either.

Creates:

- **Mgmt env-region VNet shells** (`module "mgmt_vnets"` invoking
  `Azure/avm-ptn-alz-sub-vending/azure` once per
  `networking.envs.mgmt.regions.<region>` entry, `mesh_peering_enabled
  = true` if multiple mgmt regions, `enable_telemetry = false`). Each
  VNet is named `vnet-<fleet.name>-mgmt-<region>` in
  `rg-net-mgmt-<region>`. `hub_peering_enabled` is set from
  `networking.envs.mgmt.regions.<region>.hub_network_resource_id`:
  non-null → `true` with that id as the target; null → `false`
  (mgmt env-region opts out of hub peering).
  The sub-vending module does **not** pre-create any per-cluster
  subnets; `bootstrap/environment` carves those (api pool, nodes
  pool, env-PE, node ASG, route table) as azapi children in a later
  apply.
- **Fleet-plane subnets** on each mgmt env-region VNet (derived CIDRs
  per §3.4 / docs/naming.md):
  - `snet-pe-fleet` — `/26` in the fleet-plane zone of the mgmt
    VNet; houses the tfstate SA PE, fleet KV PE, fleet ACR PE. NSG
    `nsg-pe-fleet-<region>` authored here.
  - `snet-runners` — `/23` in the fleet-plane zone; delegated to
    `Microsoft.App/environments` for the ACA runner pool's Container
    App Environment. NSG `nsg-runners-<region>` authored here.
    `route_table` UDR for hub-egress is adopter-referenced (BYO).
  Existing PE/ACA references in `main.state.tf` / `main.fleet-kv.tf`
  / `main.runner.tf` / `main.acr.tf` (fleet ACR PE) land on these
  derived subnet ids; `_fleet.yaml` exposes no operator-visible
  subnet-id fields for them.
- **`Network Contributor` on each mgmt env-region VNet resource id
  → `fleet-meta` UAMI** — lets `bootstrap/environment` carve
  cluster-workload subnets onto the pre-existing mgmt VNets under
  the `fleet-meta` identity, and write the mgmt→spoke half of every
  non-mgmt-env peering when `create_reverse_peering = true`.
- **Fleet TF state storage account** (`rg-fleet-tfstate`) with
  `tfstate-fleet` container, soft-delete + versioning on. All downstream
  stages' state lands here (including per-env containers).
- **`fleet-stage0` UAMI** + federated credential
  `repo:<org>/fleet:environment:fleet-stage0`. RBAC:
  `Contributor` on `rg-fleet-shared`; `Storage Blob Data Contributor` on
  `tfstate-fleet` container; `Application Administrator` on Entra
  (needed for AAD app CRUD) or tightened to app-owner on pre-created
  apps if policy forbids tenant-wide role.
- **`fleet-meta` UAMI** + federated credential
  `repo:<org>/fleet:environment:fleet-meta`. RBAC:
  `User Access Administrator` + `Contributor` at
  tenant-root/per-subscription (scope per subscription model);
  `Application Administrator` on Entra. This is the privileged identity
  used by env-bootstrap and team-bootstrap workflows.
- **`fleet-meta` GitHub App** (admin-class) and **`stage0-publisher`
  GitHub App** (narrow). Both are created **out of band** by the
  `init-gh-apps.sh` helper (§16.4) before this stage runs, because
  the GitHub App Manifest flow requires a one-time browser consent
  click that no API can bypass. **`bootstrap/fleet` does not touch
  GH App credentials** — the fleet Key Vault is created by
  `bootstrap/fleet` itself, but storing the PEMs / webhook secrets
  there is Stage 0's job (Stage 0 holds `Key Vault Secrets Officer`
  on the vault for exactly this purpose). `bootstrap/fleet`'s only
  involvement with the Apps is creating the `fleet-stage0` /
  `fleet-meta` GitHub environments that Stage 0 later populates
  with App-derived variables.
  - Required permissions per App (asserted by the manifest):
    - `fleet-meta`: `administration:write`, `environments:write`,
      `variables:write`, `secrets:write`, `contents:write` —
      the privileged identity used by env-bootstrap and
      team-bootstrap workflows.
    - `stage0-publisher`: `variables:write` only — used by the
      Stage 0 workflow to publish outputs as repo variables (§10).
- **Fleet GitHub repo** — **created** via the organization's user-supplied
  **GH-repo Terraform module** (module source TBD; placeholder in Phase 1
  scaffold; replaced once published module path is known). Applies branch
  protection on `main` (required reviews, required checks, Kargo bot
  path exemption on
  `platform-gitops/components/*/environments/{dev,staging}/values.yaml`).
  Idempotent: if the repo already exists from a prior run, managed as
  data (no create).
- **`fleet-stage0` and `fleet-meta` GitHub environments** on the fleet
  repo, with their variables/secrets populated.
- **Team-repo template repo** (`<org>/team-repo-template`) — created
  via the same GH-repo module, seeded with `services/<example>/{base,environments}`
  layout, CI for image build/push to fleet ACR, and README.

State backend: local (bootstrap creates the remote backend).

Re-run trigger: rare — rotate `fleet-meta` / `fleet-stage0` federated-credential
subjects (e.g. repo rename or org move), rebuild/rotate meta UAMIs or their
RBAC, change fleet-repo settings owned by this stage (branch protection,
`fleet-stage0` / `fleet-meta` environment reviewer policy), bump the GH-repo
module version, or add a new fleet-wide meta identity. Adding a new
environment does **not** require re-running Stage -1 — that is handled
entirely by `bootstrap/environment`.

##### Runner infrastructure

`bootstrap/fleet` also stands up the fleet's **single shared self-hosted
GitHub Actions runner pool** so every downstream tfstate-writing workflow
(`env-bootstrap.yaml`, `team-bootstrap.yaml`, `tf-plan.yaml`, `tf-apply.yaml`,
`stage0.yaml`) can run inside the adopter's VNet and reach the private-only
tfstate storage account. Implementation lives in
`terraform/bootstrap/fleet/main.runner.tf` and calls the vendored
`terraform/modules/cicd-runners/` module (see its `VENDORING.md` for the
delta against upstream `Azure/terraform-azurerm-avm-ptn-cicd-agents-and-runners@v0.5.2`).

Key design choices:

- **Single pool, repo-scoped**, label `self-hosted`. The trust boundary for
  what each workflow can touch is the GitHub Environment + federated credential
  (per-env `fleet-<env>` UAMI, `fleet-meta` for env/team bootstrap,
  `fleet-stage0` for Stage 0), **not** network reachability. A shared pool
  keeps runner plumbing off the critical path for new envs.
- **GH App authentication for KEDA polling**, driven by a dedicated
  `fleet-runners` GitHub App (third App in the inventory alongside
  `fleet-meta` and `stage0-publisher` — see §16.4). Permissions:
  `actions:read` + `metadata:read`. The PEM lives in the fleet KV under
  `fleet-runners-app-pem` (seeded post-bootstrap by `init-gh-apps.sh`;
  see §16.4) and is resolved into the
  Container App Job as a **Key Vault secret reference** (`{ keyVaultUrl,
  identity }`) via a callsite-created `uami-fleet-runners` UAMI.
  `bootstrap/fleet` grants that UAMI `Key Vault Secrets User` on the
  fleet KV it creates in the same apply graph — the KV, the secret
  path, and the role assignment must all exist before ACA validates
  the Container App Job's KV reference at PUT time, which is why
  fleet-KV ownership sits in Stage -1 rather than Stage 0. The PEM
  never enters Terraform state. Vendor patch documented in
  `modules/cicd-runners/VENDORING.md` §4.
- **Private tfstate SA**: `bootstrap/fleet/main.state.tf` sets
  `publicNetworkAccess = var.allow_public_state_during_bootstrap ? "Enabled"
  : "Disabled"` (default `false`) with `networkAcls.defaultAction = "Deny"`
  always, and seeds a `Microsoft.Network/privateEndpoints` + optional
  `privateDnsZoneGroups` child referencing the central
  `privatelink.blob.core.windows.net` zone from `_fleet.yaml`. **Two-phase
  first apply** (see Prerequisites above): first apply with
  `allow_public_state_during_bootstrap = true` to seed the PE / DNS zone
  group; second apply (and every subsequent re-run) with the flag flipped
  back to `false`, from a VNet-reachable workstation.
- **Per-pool private ACR + per-pool LAW** (`container_registry_creation_enabled
  = true`, `log_analytics_workspace_creation_enabled = true`). Keeps the
  runner plumbing off the fleet-ACR ABAC delegation path and gives each
  pool its own observability scope. The per-pool ACR's private endpoint
  registers into a **pre-existing central `privatelink.azurecr.io` zone**
  (typically in the hub connectivity sub, symmetric with the tfstate
  zone); the module explicitly sets
  `container_registry_private_dns_zone_creation_enabled = false` and
  passes `container_registry_dns_zone_id` from
  `_fleet.yaml.networking.runner.container_registry_private_dns_zone_id`.
  No zone is created by this repo, and no VNet→zone link is created by
  the module (hence no `virtual_network_id` input is required at the
  callsite).
- **No NAT, no public IP** at the module callsite. Egress flows through the
  hub firewall via a UDR on `snet-runners`; adopter responsibility.
- **Bring-your-own VNet**: `virtual_network_creation_enabled = false` with
  subnet IDs sourced from `_fleet.yaml.networking.{runner.*,
  tfstate.private_endpoint.*}`. See `docs/adoption.md` §3 + §5.1 for the
  full list of post-init fields.

**Stage 0 implication (follow-up, not in Stage -1):** `bootstrap/fleet`
creates the fleet KV and grants `uami-fleet-runners` `Key Vault Secrets
User` on it, but does **not** write any secret material. Stage 0 must
(a) seed `fleet-runners-app-pem` (plus the other GH App PEMs and
webhook secrets) into the fleet KV — it holds `Key Vault Secrets
Officer` on the vault via a role assignment granted in `bootstrap/fleet`
to the `fleet-stage0` UAMI — and (b) publish the `fleet-runners` App
IDs as repo variables.

**Ordering constraint:** `init-gh-apps.sh` (§16.4) must run **before**
`bootstrap/fleet` — the vendored runner module's variable validation
refuses empty `version_control_system_github_application_{id,installation_id}`
when `authentication_method = "github_app"`, so
`github_app.fleet_runners.{app_id, installation_id}` must be populated
in `clusters/_fleet.yaml` before the first `bootstrap/fleet` apply.
The PEM itself is only resolved at runtime (KV reference), so the
first apply succeeds once the IDs are present; the Container App Job
then fails deterministically at scale-out until Stage 0 seeds the
PEM. Tracked as an outside-PLAN scaffolding row in STATUS.md.

#### `bootstrap/environment/` — Actions-run via `env-bootstrap.yaml`

Executed under the `fleet-meta` GitHub environment (2-reviewer gate).
Parameterized on `env` input (`mgmt` | `nonprod` | `prod` | ...).

Creates:

- **Per-env TF state container** `tfstate-<env>` in the shared
  `tfstate-fleet` storage account.
- **Env-region VNets + cluster-workload subnets.** Behaviour differs
  by env:
  - **Non-mgmt envs (e.g. `nonprod`, `prod`).** `module "env_vnets"`
    invokes `Azure/avm-ptn-alz-sub-vending/azure` once with
    `N = len(regions)`, `mesh_peering_enabled = true`,
    `enable_telemetry = false`. Each VNet named
    `vnet-<fleet.name>-<env>-<region>` in `rg-net-<env>-<region>`.
    Per-region `hub_peering_enabled` is set from
    `networking.envs.<env>.regions.<region>.hub_network_resource_id`:
    non-null → `true` with that id as the target; null → `false`
    (env-region opts out of hub peering). The sub-vending module
    does **not** pre-create per-cluster subnets.
  - **`env=mgmt`.** The mgmt env-region VNets already exist (created
    by `bootstrap/fleet` alongside the fleet-plane subnets). This
    stage does **not** re-create them; it references them by id from
    the `MGMT_<REGION>_VNET_RESOURCE_ID` repo variable and carves
    cluster-workload subnets onto them as azapi children, using the
    `Network Contributor` grant `bootstrap/fleet` placed on the
    `fleet-meta` UAMI.
  - **Uniform cluster-workload subnets (every env, mgmt included).**
    Authored as azapi children on the env-region VNet per §3.4:
    - `snet-pe-env` — first `/26` of the cluster-reserved zone;
      houses the env Grafana PE, plus any cluster-scope PEs
      (including the mgmt cluster KV PE on mgmt VNets, which is a
      per-cluster resource owned by Stage 1 registering into this
      subnet). NSG `nsg-pe-env-<env>-<region>` authored here, with
      an inbound rule allowing `443` from `asg-nodes-<env>-<region>`.
    - **API pool and NODES pool** — reserved `/24` (api) and `/21`
      (nodes) per §3.4; Stage 1 carves per-cluster `/28`/`/25`
      subnets by `subnet_slot`.
    - **Route table** `rt-aks-<env>-<region>` with a `0.0.0.0/0`
      route to
      `networking.envs.<env>.regions.<region>.egress_next_hop_ip`
      when that field is non-null. The route table shell is created
      unconditionally (so Stage 1 can associate it on both the api
      and nodes subnets); the route entry is only authored when the
      adopter has supplied the next-hop IP. Both subnets have
      `routeTableId` set from this table (Stage 1 creates the
      per-slot associations; this stage creates the route table + the
      route entry).
- **Env↔mgmt peerings** — for every non-mgmt env-region,
  `bootstrap/environment` iterates
  `networking.envs.mgmt.regions.*` and calls
  `Azure/avm-res-network-virtualnetwork/azurerm//modules/peering`
  once per mgmt env-region. The mgmt target VNet is resolved by
  same-region match (`networking.envs.mgmt.regions.<env-region>`
  if present) with fallback to the first mgmt region. Each call
  uses `create_reverse_peering =
  networking.envs.<env>.regions.<region>.create_reverse_peering`
  (default true), names `peer-<env>-<region>-to-mgmt-<mgmt-region>`
  and `peer-mgmt-<mgmt-region>-to-<env>-<region>`. Both halves
  land in the env state when `create_reverse_peering = true`;
  only the spoke→mgmt half is authored when false. Requires
  `Network Contributor` on the mgmt VNet resource id — granted to
  the `fleet-meta` UAMI by `bootstrap/fleet` (see above). For
  `env=mgmt`, no env↔mgmt peering is authored (the mgmt VNet *is*
  the mgmt VNet); mgmt's only cross-VNet peerings are the hub
  peering emitted by its sub-vending call and the reverse halves
  authored by other envs' `bootstrap/environment` runs.
- **Node Application Security Group** (`azapi_resource`
  `Microsoft.Network/applicationSecurityGroups`) named
  `asg-nodes-<env>-<region>` in `rg-net-<env>-<region>`. One per
  env-region (mgmt included); every AKS cluster in the region
  attaches its node pool NIC identities to it via Stage 1.
  Referenced by the env PE NSG allow rule above.
- **`fleet-<env>` UAMI** + federated credential
  `repo:<org>/fleet:environment:fleet-<env>`. RBAC:
  - `Contributor` at subscription or env-root RG scope.
  - `Storage Blob Data Contributor` on `tfstate-<env>`.
  - `Key Vault Secrets User` on fleet KV.
  - `User Access Administrator` scoped **only** to the fleet ACR
    resource id, with an **ABAC condition constraining role assignments
    to the `AcrPull` role definition and `ServicePrincipal` principal
    type only**. The condition uses the v2 role-assignment condition
    syntax:

    ```
    (
      !(ActionMatches{'Microsoft.Authorization/roleAssignments/write'})
    )
    OR
    (
      @Request[Microsoft.Authorization/roleAssignments:RoleDefinitionId]
        ForAnyOfAnyValues:GuidEquals {7f951dda-4ed3-4680-a7ca-43fe172d538d}
      AND
      @Request[Microsoft.Authorization/roleAssignments:PrincipalType]
        StringEqualsIgnoreCase 'ServicePrincipal'
    )
    ```

    (`7f951dda-4ed3-4680-a7ca-43fe172d538d` = built-in `AcrPull` role
    definition GUID; `ServicePrincipal` covers both system- and
    user-assigned managed identities, which is how kubelet identities
    appear to Azure RBAC.) A symmetric clause covers
    `roleAssignments/delete` using the `@Resource[...]` attributes.
    This lets Stage 1 delegate `AcrPull` to each cluster's kubelet
    identity but prevents the `fleet-<env>` UAMI from granting any
    other role, or granting `AcrPull` to a user/group, on the ACR.
    Implemented via `azapi_resource` on
    `Microsoft.Authorization/roleAssignments@2022-04-01` with
    `properties.condition` + `properties.conditionVersion = "2.0"`.

- **`fleet-<env>` GitHub environment** via
  `github_repository_environment` with reviewer policy from input (prod
  requires 2; nonprod/mgmt 0 — see §10).
- **Env-scoped repo variables** via `github_actions_environment_variable`:
  `AZURE_CLIENT_ID`, `AZURE_TENANT_ID`, `AZURE_SUBSCRIPTION_ID`,
  `TFSTATE_CONTAINER`.
- **Env-root resource groups**: `rg-fleet-<env>-shared`, `rg-dns-<env>`
  (matches `_fleet.yaml:dns.resource_group_pattern`), `rg-obs-<env>`.
- **Network Security Perimeter** (`azapi_resource`
  `Microsoft.Network/networkSecurityPerimeters`) named
  `nsp-<fleet.name>-<env>` in `rg-obs-<env>`, with one NSP profile
  (`default`). The NSP is the ingress boundary for this env's metrics
  stack — AMW and DCE are joined via resource associations; all other
  access is denied by default.
  - **Inbound access rules** (`Microsoft.Network/networkSecurityPerimeters/profiles/accessRules`):
    - `allow-cluster-ingestion` — source `Subscriptions` =
      `[envs.<env>.subscription_id]`; permits cluster addon
      identities in this env to POST metrics to the DCE.
    - `allow-grafana-query` — source `Subscriptions` =
      `[<sub-fleet-shared or Grafana's sub>]` (Grafana lives in the
      env sub in our current layout, so same subscription); permits
      Grafana's query calls to AMW.
    - Additional `IPAddresses` rules for on-call break-glass query
      access may be appended later.
  - **Outbound rules**: default-deny; observability components don't
    need egress from the perimeter.
- **Azure Monitor Workspace** (`azapi_resource`
  `Microsoft.Monitor/accounts`) named `amw-<fleet.name>-<env>` in
  `rg-obs-<env>`, with `properties.publicNetworkAccess=Disabled`.
  Backs Managed Prometheus for every cluster in this env.
- **Data Collection Endpoint** (`azapi_resource`
  `Microsoft.Insights/dataCollectionEndpoints`) named
  `dce-<fleet.name>-<env>` in `rg-obs-<env>`, kind `Linux`, with
  `properties.networkAcls.publicNetworkAccess=Disabled`. Stage 1 DCRs
  reference this DCE so metric ingestion flows only via NSP.
- **NSP resource associations** (`azapi_resource`
  `Microsoft.Network/networkSecurityPerimeters/resourceAssociations`):
  one each for AMW and DCE, bound to the NSP profile above.
- **Azure Managed Grafana** (`azapi_resource`
  `Microsoft.Dashboard/grafana`) named `amg-<fleet.name>-<env>` with
  system-assigned managed identity, AAD authentication, `apiKey`
  disabled, zone redundancy + deterministic outbound IP per
  `observability.grafana` defaults, and
  **`properties.publicNetworkAccess=Disabled`**.
  - **Private Endpoint** (`azapi_resource`
    `Microsoft.Network/privateEndpoints`) named
    `pe-amg-<fleet.name>-<env>` in the derived `snet-pe-env` subnet
    of this env-region's VNet (emitted by the sub-vending module above),
    target subresource `grafana`.
  - **Private DNS zone**: no per-env zone is created. The Grafana PE
    registers into the central
    `_fleet.yaml.networking.private_dns_zones.grafana` zone (BYO).
    VNet links to that central zone cover both the env VNet and the
    mgmt VNet.
  - **PE DNS zone group** (`privateEndpoints/privateDnsZoneGroups`)
    registering the PE IP into the private DNS zone.
  - **AMW integration**: `azapi_resource`
    `Microsoft.Dashboard/grafana/integrations/azureMonitorWorkspaceIntegrations`
    attaches this env's AMW as the default Prometheus data source. The
    actual query traffic flows over AAD-auth HTTPS and is permitted by
    the NSP `allow-grafana-query` inbound rule.
  - **Role assignments** (all via `azapi_resource`
    `Microsoft.Authorization/roleAssignments`):
    - Grafana SAMI → `Monitoring Reader` on this env's subscription
      (service discovery of AKS / AMW / LAW within the env only;
      prod Grafana cannot read nonprod resources and vice versa).
    - Grafana SAMI → `Monitoring Data Reader` on the env AMW resource
      id.
    - `envs.<env>.grafana.admins` group → `Grafana Admin` on
      the Grafana resource id.
    - `envs.<env>.grafana.editors` group (if non-empty) →
      `Grafana Editor`.
- **Azure Monitor Action Group** (`azapi_resource`
  `Microsoft.Insights/actionGroups`) named `ag-<fleet.name>-<env>` in
  `rg-obs-<env>`, with receivers rendered from
  `envs.<env>.action_group.receivers`. Receiver secrets
  (PagerDuty integration keys, Slack webhooks) are read from the fleet
  KV using the secret names declared in `_fleet.yaml` — values must be
  seeded out-of-band before running `env-bootstrap.yaml`.
- Outputs (published as env-scoped repo variables by the
  `env-bootstrap.yaml` workflow): `MONITOR_WORKSPACE_ID_<ENV>`,
  `MONITOR_WORKSPACE_QUERY_ENDPOINT_<ENV>`, `DCE_ID_<ENV>`,
  `DCE_LOGS_INGESTION_ENDPOINT_<ENV>`, `DCE_METRICS_INGESTION_ENDPOINT_<ENV>`,
  `GRAFANA_ID_<ENV>`, `GRAFANA_ENDPOINT_<ENV>`, `ACTION_GROUP_ID_<ENV>`,
  `NSP_ID_<ENV>`, plus per-region networking outputs
  `<ENV>_<REGION>_VNET_RESOURCE_ID` and
  `<ENV>_<REGION>_NODE_ASG_RESOURCE_ID` (consumed by Stage 1 for
  per-cluster subnet parent refs, AKS ASG attachment, and private
  DNS zone VNet links). Stage 1 does **not** consume the obs
  outputs — it looks resources up by derived name via `azapi` data
  sources (§4 Stage 1). The obs variables exist for dashboard links
  and PR-comment summaries only.

State backend: `tfstate-fleet` container, key
`bootstrap/environment/<env>.tfstate`. Authed via `fleet-meta` UAMI.

Trigger: `workflow_dispatch` with `env` input; optionally also on
PR-merge that adds `clusters/<new-env>/_defaults.yaml`.

#### `bootstrap/team/` — Actions-run via `team-bootstrap.yaml`

Executed under `fleet-meta` (or a narrower team-bootstrap environment
if we elect to mint a smaller GH App — see §15). Triggered on PR merge
to `main` that adds a new `platform-gitops/config/teams/<team>.yaml`.

Creates:

- **Team GitHub repo** (`<org>/<team>-gitops`) from the
  `team-repo-template` via the user-supplied GH-repo module.
- Team AAD security group not managed here (owned by IGA/IdP).
- Kargo GitHub App installation on the new repo via the
  `fleet-meta` App's admin scope.
- Branch protection on `main` of the team repo; CODEOWNERS seeded
  pointing at the team's GH team.

State backend: `tfstate-fleet` container, key
`bootstrap/team/<team>.tfstate`.

### Stage 0 — `terraform/stages/0-fleet`

Fleet-global, applied once and thereafter on additions only. Single state
file `fleet.tfstate` in a dedicated `tfstate-fleet` container.

Creates:

- **Azure Container Registry** (`azapi_resource`
  `Microsoft.ContainerService/registries` — Premium SKU for
  geo-replication + OCI artifact / Helm chart support). Single registry
  for all fleet images and Helm charts; teams push to
  `<acr>.azurecr.io/<team>/<image>` and `<acr>.azurecr.io/helm/<chart>`.
- **Fleet Key Vault secrets** — the vault itself
  (`Microsoft.KeyVault/vaults`, Standard SKU, RBAC authorization mode,
  purge protection on, strictly private) is created by `bootstrap/fleet`
  (Stage -1); Stage 0 references it by a derived id reconstructed from
  `_fleet.yaml` (no data-source lookup — avoids needing read-plane
  permissions at plan time) and holds `Key Vault Secrets Officer` on
  the vault (role assignment granted to the `fleet-stage0` UAMI in
  `bootstrap/fleet`). Stage 0 is responsible for **seeding and
  rotating** the fleet-wide secret material — values that must be read
  by more than one cluster. Per-cluster or single-cluster secrets
  belong in that cluster's own KV.
  - `argocd-github-app-pem` — every cluster's ArgoCD reads it to
    authenticate to GitHub for platform-gitops pulls.
  - `argocd-oidc-client-secret` — every cluster's ArgoCD reads it for
    human SSO auth-code flow.
  - `fleet-meta-app-pem`, `fleet-meta-webhook-secret`,
    `stage0-publisher-app-pem`, `stage0-publisher-webhook-secret`,
    `fleet-runners-app-pem`, `fleet-runners-webhook-secret` —
    the three GH Apps created out-of-band by `init-gh-apps.sh`
    (§16.4). Values are consumed from the repo-root
    `.gh-apps.auto.tfvars` overlay this stage reads in addition to
    its normal tfvars.json. Downstream workflows read them at run
    time via the `fleet-meta` / `stage0-publisher` UAMIs; the
    `fleet-runners-app-pem` is consumed by the runner-pool
    Container App Job via Key Vault secret reference (never
    plaintext in state, never via Terraform read). `bootstrap/fleet`
    creates the vault with no secrets in it; the runner pool's
    Container App Job deterministically fails scale-out until
    Stage 0 seeds the PEM (tracked as an ordering constraint in
    §4 Stage -1 `bootstrap/fleet` → *Runner infrastructure*).
  - additional fleet-wide secrets added over time.
  Kargo GitHub App PEM and Kargo OIDC client secret are **not** here
  — only the mgmt cluster uses them, so they live in the mgmt
  cluster's KV (see Stage 1).
- **Argo AAD application registration** (`azuread_application`) —
  single-tenant (`sign_in_audience = "AzureADMyOrg"`), used as the
  OIDC client by every cluster's ArgoCD. `group_membership_claims =
["SecurityGroup"]`. The `web.redirect_uris` list is **computed at
  Stage 0 time** from the cluster YAML inventory — each cluster's
  Argo callback URL is derivable from its directory path
  (`https://argocd.<name>.<region>.<env>.<fleet_root>/auth/callback`).
  Stage 0 owns the complete list atomically; no per-cluster Stage 1
  PATCH is needed, which eliminates the read-modify-write race that
  parallel Stage 1 jobs would otherwise have on a shared AAD app.
  Adding or removing a cluster → Stage 0 re-apply → redirect list
  updated in one transaction.
  **Federated Identity Credentials on this AAD app**
  (`azuread_application_federated_identity_credential`) are added
  per cluster in Stage 2 (needs the AKS OIDC issuer URL, a Stage 1
  output). Subject =
  `system:serviceaccount:argocd:argocd-server`, audience =
  `api://AzureADTokenExchange`. These let Argo authenticate to
  AAD-protected APIs as the Argo app without any shared secret
  (workload→AAD direction).
  A **single RP `client_secret`** is still required solely for the
  OIDC auth-code flow (human SSO login) — Argo's upstream OIDC/Dex
  does not yet support `client_assertion` RP authentication. Managed
  as an `azuread_application_password` with `end_date_relative =
"2160h"` (90 days) and a `rotate_when_changed` keeper pinned to a
  `time_rotating` resource (`rotation_days = 60`). TF handles
  rotation inline: on each apply, if the keeper has advanced, a new
  password is created before the old one is destroyed — so the
  existing secret remains valid through the rotation window while
  ESO fans out the new value. The resulting `.value` is written to
  the fleet KV as an `azapi_resource`
  `Microsoft.KeyVault/vaults/secrets` (new secret version); ESO on
  each cluster syncs it into the `argocd` namespace and Argo reloads
  on secret change. No out-of-band rotation workflow needed.
- **Kargo AAD application registration** (`azuread_application`) —
  same shape as the Argo app. `web.redirect_uris` contains only the
  **mgmt cluster's** Kargo callback URL (derived from the mgmt
  cluster's directory path the same way Argo URIs are).
  **The `azuread_application_password` for Kargo is NOT created here**
  — it's created in the mgmt cluster's Stage 1 alongside the mgmt
  cluster KV that stores it (see Stage 1). Stage 0 only exports
  `kargo_aad_application_id` and `kargo_aad_application_object_id`
  for downstream stages. This keeps the secret and its destination
  KV in the same plan, and keeps a mgmt-only secret out of the
  fleet-wide KV.
  Per-cluster FICs on the Kargo AAD app are still added in Stage 2,
  gated on `cluster.role == "management"` (covering
  `system:serviceaccount:kargo:kargo-controller` and
  `system:serviceaccount:kargo:kargo-api`).
- Group-claim configuration on both apps so `groups` claim emits security
  group object IDs (these match `oidcGroup` in team YAML).
- The RP `client_secret` values above are the **only fleet secrets
  under TF auto-rotation**; every other AAD↔workload and
  AAD↔CI credential is federated (FIC).
- **Kargo mgmt UAMI** (`azapi_resource`
  `Microsoft.ManagedIdentity/userAssignedIdentities`) named
  `uami-kargo-mgmt`, placed in `rg-fleet-shared` in
  `sub-fleet-shared`. It's a fleet-wide singleton (exactly one,
  attached to the mgmt cluster) so it lives here, not in any
  cluster's Stage 1, which means its `principalId` flows through
  the standard Stage 0 → repo variable publish path and is
  consumed by every workload cluster's Stage 1 as
  `vars.KARGO_MGMT_UAMI_PRINCIPAL_ID`. No cross-cluster CI
  ordering or cross-subscription data-source lookup required.
  Carries two role assignments total across the fleet:
  - **`AcrPull` on the fleet ACR** — granted here in Stage 0. Lets
    Kargo Warehouses that subscribe to ACR repositories authenticate
    as this UAMI (no image-pull secrets).
  - **`AKS RBAC Reader` on every workload AKS cluster** — granted
    in each workload cluster's Stage 1 (see Stage 1 role
    assignments). Lets Kargo read Argo `Application` CRs on
    workload clusters for health verification.
  Azure Workload Identity annotates a K8s ServiceAccount with
  exactly one `client-id`, so the Kargo controller SA federates to
  exactly this one UAMI — both capabilities must live on it.
  The **FIC** binding this UAMI to the Kargo controller SA
  (`system:serviceaccount:kargo:kargo-controller` on the mgmt
  cluster) is created by the **mgmt cluster's Stage 2** (where
  the mgmt AKS OIDC issuer URL is available).
Outputs — published to fleet-wide GitHub repository variables by the
Stage 0 workflow (via the `stage0-publisher` GitHub App) and consumed
by downstream stages as `vars.<UPPER_SNAKE_NAME>`. All values are
non-sensitive identity facts (ids, names, principal/client ids); no
secret material is ever a Stage 0 output.

**Fleet shared infrastructure**

| TF output                     | Repo variable                   | Consumed by                                                                                             |
| ----------------------------- | ------------------------------- | ------------------------------------------------------------------------------------------------------- |
| `acr_login_server`            | `ACR_LOGIN_SERVER`              | Stage 1 (AcrPull target hint); Stage 2 (Argo/Kargo Helm image refs); team repo CI for `docker push`     |
| `acr_resource_id`             | `ACR_RESOURCE_ID`               | Stage 1 (AcrPull role-assignment scope for each cluster's kubelet identity)                             |
| `fleet_keyvault_id`           | `FLEET_KEYVAULT_ID`             | Stage 1 (`Key Vault Secrets User` role-assignment scope for each cluster's ESO UAMI)                    |
| `fleet_keyvault_name`         | `FLEET_KEYVAULT_NAME`           | Stage 2 (`platform-identity` secret, ESO `ClusterSecretStore`, ephemeral azapi KV read for Argo creds)  |
| `fleet_resource_group_name`   | `FLEET_RESOURCE_GROUP_NAME`     | Stage 1 (scoping lookups) — informational                                                               |

**AAD applications** (object_id = directory object id; application_id = client id / `appId`)

| TF output                               | Repo variable                             | Consumed by                                                                                                                       |
| --------------------------------------- | ----------------------------------------- | --------------------------------------------------------------------------------------------------------------------------------- |
| `argocd_aad_application_id`             | `ARGOCD_AAD_APPLICATION_ID`               | Stage 2 on every cluster — Argo Helm OIDC `clientID`; `platform-identity` secret                                                  |
| `argocd_aad_application_object_id`      | `ARGOCD_AAD_APPLICATION_OBJECT_ID`        | Stage 2 on every cluster — parent ref for per-cluster `azuread_application_federated_identity_credential`                         |
| `kargo_aad_application_id`              | `KARGO_AAD_APPLICATION_ID`                | Mgmt Stage 2 — Kargo Helm OIDC `clientID`                                                                                         |
| `kargo_aad_application_object_id`       | `KARGO_AAD_APPLICATION_OBJECT_ID`         | Mgmt Stage 1 — parent ref for `azuread_application_password` (Kargo RP secret generation); mgmt Stage 2 — parent ref for Kargo FIC |

**Kargo mgmt UAMI** (fleet-wide singleton, single SA federates to it)

| TF output                         | Repo variable                       | Consumed by                                                                                                                 |
| --------------------------------- | ----------------------------------- | --------------------------------------------------------------------------------------------------------------------------- |
| `kargo_mgmt_uami_resource_id`     | `KARGO_MGMT_UAMI_RESOURCE_ID`       | Mgmt Stage 2 — parent ref for `fc-kargo-mgmt` FIC (`.../federatedIdentityCredentials`)                                      |
| `kargo_mgmt_uami_principal_id`    | `KARGO_MGMT_UAMI_PRINCIPAL_ID`      | Every workload cluster's Stage 1 — `AKS RBAC Reader` role-assignment `properties.principalId` on the workload AKS resource  |
| `kargo_mgmt_uami_client_id`       | `KARGO_MGMT_UAMI_CLIENT_ID`         | Mgmt Stage 2 — `azure.workload.identity/client-id` annotation on the `kargo-controller` ServiceAccount                      |

**GitHub Apps** (Apps themselves are created by `init-gh-apps.sh`
out-of-band per §16.4; Stage 0 receives their ids/client ids as
inputs via `.gh-apps.auto.tfvars` and publishes them as repo
variables so downstream workflows can mint installation tokens)

| TF output                           | Repo variable                  | Consumed by                                                                                      |
| ----------------------------------- | ------------------------------ | ------------------------------------------------------------------------------------------------ |
| `fleet_meta_app_id`                 | `FLEET_META_APP_ID`            | `env-bootstrap.yaml`, `team-bootstrap.yaml` — installation-token minting under `fleet-meta` UAMI |
| `fleet_meta_app_client_id`          | `FLEET_META_APP_CLIENT_ID`     | same workflows — App client id for JWT `iss` claim                                               |
| `stage0_publisher_app_id`           | `STAGE0_PUBLISHER_APP_ID`      | `tf-apply.yaml` (Stage 0 `publish-stage0-outputs` step) — token to `PATCH` repo variables        |
| `stage0_publisher_app_client_id`    | `STAGE0_PUBLISHER_APP_CLIENT_ID`| same                                                                                             |


**Not published as repo variables** (available from other sources, no indirection needed):

- `tenant_id`, `subscription_id` — already env variables on the `fleet-<env>` GitHub environment; Stage 0 doesn't re-export them.
- Fleet KV secret *names* (e.g., `argocd-github-app-pem`, `argocd-oidc-client-secret`) — string constants, declared as `locals` in Stage 2, not Stage 0 outputs.
- AAD app RP `client_secret` values — never outputs; materialized by `azuread_application_password` into fleet KV (Argo) or mgmt cluster KV (Kargo, in Stage 1).

**Publishing mechanism**: a final `publish-stage0-outputs` step in
`.github/workflows/tf-apply.yaml` calls `terraform -chdir=... output
-json` and, for each entry above, `PATCH /repos/{org}/{repo}/actions/variables/{name}`
authenticated as the `stage0-publisher` GitHub App. Absent variables
are created with `POST`. The App's only permission on the repo is
`variables:write`, so even a compromised Stage 0 run cannot touch
secrets, code, or environment-scoped variables.

The **per-env observability stack** (Azure Monitor Workspace + Managed
Grafana + Action Group) is **not** created here — it lives in
`bootstrap/environment` so its lifecycle matches env onboarding, its
state file sits alongside the env's other env-scope resources, and
prod's stack is never touched when a new non-prod env is added. See
§4.1.

Why AAD apps live in Terraform: they are long-lived, fleet-wide identity
artifacts; their client IDs must be pinned into both per-cluster Argo
helm values and the `platform-identity` secret. Managing them as code
keeps redirect URI additions PR-reviewed and tracked alongside cluster
onboarding.

Stage 0 depends on: `bootstrap/fleet` (Stage -1) — the fleet KV it
seeds secrets into, and the `fleet-stage0` UAMI + GitHub environment
it runs under, are all created there. Stage 0 does **not** create
per-cluster KVs — those are created in Stage 1 when the owning cluster
is provisioned. It also no longer creates the fleet KV itself; it only
seeds / rotates secrets inside it and publishes its id/name as repo
variables for downstream consumption.

### Stage 1 — `terraform/stages/1-cluster`

Inputs: merged tfvars.json produced from the cluster YAML hierarchy.

Creates:

- AKS cluster via the **`Azure/avm-res-containerservice-managedcluster/azurerm`**
  AVM module (pin to the latest `azapi`-based release) with OIDC issuer
  - workload identity enabled. `kubernetes_version` bound to
    `kubernetes.version`. Cluster-autoscaler profile applied from
    `kubernetes.cluster_autoscaler_profile`.
  - **Entra-only auth** (hard-coded in `modules/aks-cluster`; not
    overridable per cluster):
    - `properties.disableLocalAccounts = true` — no `clusterUser` or
      `clusterAdmin` kubeconfig ever exists; `listClusterAdminCredential`
      / `listClusterUserCredential` return tokens that fail auth.
    - `properties.aadProfile.managed = true`
    - `properties.aadProfile.enableAzureRBAC = true` — K8s API
      authorization decisions are delegated to Azure RBAC.
    - `properties.aadProfile.tenantID = aad.aks.tenant_id`
    - `properties.aadProfile.adminGroupObjectIDs =
envs.<env>.aks.admin_groups` — pure break-glass; members
      bypass K8s RBAC entirely. Intentionally kept tight.
- System and apps node pools per `node_pools.*`; autoscaling enabled
  (`min_count` / `max_count`) on each.
- **Cluster Key Vault** (`azapi_resource` `Microsoft.KeyVault/vaults`,
  Standard SKU, RBAC authorization, purge protection on) named
  `<keyvault.name>` (derived per §3.3) in `<keyvault.resource_group>`.
  Holds cluster-local secrets: TLS wildcard, observability API keys,
  team-owned app secrets. On the **management cluster only**, also
  holds Kargo-specific fleet secrets (only the mgmt cluster reads
  them):
  - `kargo-oidc-client-secret` — created in this same Stage 1 plan
    as an `azuread_application_password` on the Stage 0-owned Kargo
    app (referenced via `vars.KARGO_AAD_APPLICATION_OBJECT_ID`),
    `end_date_relative = "2160h"`, `rotate_when_changed` keyed off
    a `time_rotating` resource (`rotation_days = 60`),
    create-before-destroy — then the resulting `.value` is written
    via `azapi_resource` `Microsoft.KeyVault/vaults/secrets`.
  - `kargo-github-app-pem` — seeded out-of-band (initial manual
    write by the operator onboarding the Kargo GitHub App, or via
    a one-shot `bootstrap/` helper); ESO then owns ongoing
    rotation as documented in §8.
  Both blocks live behind a `cluster.role == "management"` gate;
  workload clusters' KVs don't contain them.
- User-assigned managed identities (`azapi_resource`
  `Microsoft.ManagedIdentity/userAssignedIdentities`):
  - `uami-external-dns-<cluster>`
  - `uami-eso-<cluster>`
  - `uami-team-<team>-<cluster>` for every team in `teams:`
  - The **Kargo mgmt UAMI** (`uami-kargo-mgmt`) is **not** created
    here — it's a fleet-wide singleton and lives in Stage 0 so its
    `principalId` propagates via the standard Stage 0 → repo
    variable path. The FIC on it is created by the mgmt cluster's
    Stage 2 (needs the mgmt AKS OIDC issuer URL).
- Federated Identity Credentials (`azapi_resource`
  `Microsoft.ManagedIdentity/userAssignedIdentities/federatedIdentityCredentials`)
  created in Stage 2 (needs the AKS OIDC issuer URL output by Stage 1).
- Role assignments (`azapi_resource`
  `Microsoft.Authorization/roleAssignments` at the appropriate scope):
  - **Private DNS Zone Contributor** scoped to the cluster's own
    `Microsoft.Network/privateDnsZones` resource id → external-dns UAMI.
    Blast radius is this one zone; no cross-cluster write access.
  - **Key Vault Secrets User on the cluster KV** → ESO UAMI. Primary
    source of cluster-local secrets.
  - **Key Vault Secrets User on the fleet KV** (scope id consumed via
    `vars.FLEET_KEYVAULT_ID`, published by Stage 0; the KV itself is
    owned by `bootstrap/fleet`) → ESO UAMI. Needed for fleet-wide
    secrets (GH App PEMs if consumed in-cluster, any additional fleet
    secrets).
  - **`AcrPull` on the fleet ACR** → cluster kubelet identity (read from
    Stage 0 remote state output `acr_resource_id`).
  - **`Azure Kubernetes Service RBAC Cluster Admin`** on the AKS
    resource id → `fleet-<env>` UAMI. Required because local accounts
    are disabled; Stage 2 must authenticate to the K8s API via AAD
    (OAuth2 client-assertion exchange using the job's GitHub OIDC JWT,
    see Stage 2 for the curl/jq recipe) and needs cluster-admin to
    create namespaces, install helm releases, and bootstrap ArgoCD.
  - **`Azure Kubernetes Service RBAC Cluster Admin`** → every group in
    `envs.<cluster.env>.aks.rbac_cluster_admins`. Human
    platform-team access via AAD SSO (`az aks get-credentials` or direct
    `az account get-access-token --resource <AKS AAD server app>`).
  - **`Azure Kubernetes Service RBAC Reader`** → every group in
    `envs.<cluster.env>.aks.rbac_readers` (if any). Read-only
    human access.
  - **`Azure Kubernetes Service Cluster User Role`** on the AKS
    resource → every group in `rbac_cluster_admins` / `rbac_readers`.
    Required by `az aks get-credentials` (human workflow) to fetch
    the AAD-auth kubeconfig stub. The CI bot does **not** need this
    role because Stage 2 constructs its provider auth config directly from
    Stage 1 outputs (host + CA + pre-exchanged AAD bearer token);
    it never calls `listClusterUserCredential`.
  - **`Azure Kubernetes Service RBAC Reader`** → Kargo mgmt-cluster
    UAMI, on **every workload cluster in the fleet** (not the mgmt
    cluster itself). Enables Kargo to read Argo `Application` CRs for
    health verification without write access. The Kargo UAMI
    `principalId` is consumed as a tfvar
    (`var.kargo_mgmt_uami_principal_id`) populated from the
    fleet-wide repo variable `KARGO_MGMT_UAMI_PRINCIPAL_ID` — a
    normal Stage 0 output, since the UAMI itself is created in
    Stage 0 as a fleet-wide singleton. The role assignment body
    only needs `principalId`, so a single string is sufficient.
    Skipped when `cluster.role == "management"`. No plan-time
    Azure data-source call, no cross-subscription read, no
    cross-cluster CI-ordering dependency — the Kargo UAMI exists
    after the very first Stage 0 apply, well before any cluster.
  - **`Monitoring Metrics Publisher` on this env's AMW** → AKS
    cluster's data-collection identity (the AKS-managed addon
    identity surfaced when `azureMonitorProfile.metrics.enabled=true`).
    The AMW is resolved via an `azapi` data source on
    `Microsoft.Monitor/accounts/amw-<fleet.name>-<cluster.env>` in
    `rg-obs-<cluster.env>`. Lets the cluster push scraped Prometheus
    metrics only to its own env's workspace — prod clusters cannot
    write nonprod metrics.
- **Managed Prometheus wiring** (enabled unless
  `platform.observability.managed_prometheus.enabled=false`):
  - AKS `properties.azureMonitorProfile.metrics.enabled=true` on the
    AVM module input, with `kubeStateMetrics` labels/annotations allowlists
    from `_defaults.yaml`.
  - **Data Collection Rule** (`azapi_resource`
    `Microsoft.Insights/dataCollectionRules`, kind `Linux`) named
    `dcr-prom-<cluster.name>` in the cluster's resource group,
    referencing the env DCE via
    `properties.dataCollectionEndpointId` (resolved by `azapi` data
    source on `Microsoft.Insights/dataCollectionEndpoints/dce-<fleet.name>-<cluster.env>`
    in `rg-obs-<cluster.env>`). Destinations: the env AMW (resolved by
    derived name) with the standard `Microsoft-PrometheusMetrics`
    stream and default scrape configuration. All ingestion traffic
    transits the env NSP — no public path exists.
  - **Data Collection Rule Association** (`azapi_resource`
    `Microsoft.Insights/dataCollectionRuleAssociations`) binding the
    DCR to the AKS resource id.
  - **Recording / alert rule groups** (`azapi_resource`
    `Microsoft.AlertsManagement/prometheusRuleGroups`) for the
    node-exporter + kube-state baseline, scoped to this env's AMW and
    referencing the env Action Group `ag-<fleet.name>-<cluster.env>`
    (also looked up by derived name). Rule bodies shipped from
    `terraform/modules/aks-cluster/rules/*.yaml` so platform-owned
    alerts are versioned alongside cluster code.
- **Per-cluster subnets** (`azapi_resource`
  `Microsoft.Network/virtualNetworks/subnets@<pinned>`) as children of
  the env VNet (parent id from
  `vars.<ENV>_<REGION>_VNET_RESOURCE_ID`). Two subnets per cluster,
  CIDRs derived by the config-loader from `networking.subnet_slot` per
  §3.4 / docs/naming.md:
  - `snet-aks-api-<cluster.name>` — `/28`, i-th slot in the env
    VNet's API pool; delegated to
    `Microsoft.ContainerService/managedClusters` and used by the AKS
    API-server VNet integration (private cluster). Must be exactly
    `/28` per AKS requirements.
  - `snet-aks-nodes-<cluster.name>` — `/25`, i-th slot in the env
    VNet's nodes pool; used by AKS node pools. Azure CNI Overlay
    with Cilium means pod IPs come from `networking.pod_cidr`, not
    this subnet.
  These subnets are authored as azapi children (not via the env-VNet
  sub-vending module) so cluster lifecycle is independent of
  `bootstrap/environment` re-applies.
- **AKS node pool ASG attachment** — the AVM AKS module's agent-pool
  input is passed
  `networkProfile.applicationSecurityGroups = [vars.<ENV>_<REGION>_NODE_ASG_RESOURCE_ID]`
  so each node NIC joins the env-region ASG. Fallback (if the pinned
  AKS API version does not expose ASG on agent pools): author NSG
  rules on `nsg-pe-env-<env>-<region>` scoped to this cluster's node
  subnet via cross-stage `Network Contributor` pre-granted by
  `bootstrap/environment`. Decision point confirmed at implementation
  time; tracked in `_TASK.md`.
- **Per-cluster private DNS zone** (`azapi_resource`
  `Microsoft.Network/privateDnsZones`) at `<dns.zone_fqdn>` (derived by
  config-loader per §3.3) in resource group `<dns.zone_rg>`, plus
  `Microsoft.Network/privateDnsZones/virtualNetworkLinks` to the
  derived link list — this cluster's env-region VNet
  (`vars.<ENV>_<REGION>_VNET_RESOURCE_ID`) plus the mgmt env-region
  VNet in the same region (`vars.MGMT_<REGION>_VNET_RESOURCE_ID`);
  mgmt clusters collapse to a single link. External-dns is later
  configured (via platform-gitops values) with
  `--domain-filter=<zone.fqdn>` and `--txt-owner-id=<cluster.name>`.
- **Argo / Kargo redirect URIs** — not touched by Stage 1. The complete
  list lives on the Stage 0-owned `azuread_application` resources,
  derived from the cluster YAML inventory. Adding a new cluster
  triggers a Stage 0 re-apply (standard fan-out); the redirect list
  is updated atomically there.

Outputs (all consumed by Stage 2 in the same CI job — see §10):

- `aks_host`, `aks_cluster_ca_certificate` (sensitive), `aks_oidc_issuer_url`
- `external_dns_identity_{client_id,resource_id}`
- `eso_identity_{client_id,resource_id}`
- `team_identities` map `{ <team> = { client_id, resource_id } }`
- `cluster_keyvault_id`, `cluster_keyvault_name`
- `fleet_keyvault_id`, `fleet_keyvault_name` (passed through from Stage 0 for convenience)
- `dns_zone_fqdn`, `dns_zone_resource_id`, `ingress_domain`
- `prometheus_dcr_id`, `prometheus_query_endpoint` (passthrough of AMW
  query endpoint for in-cluster consumers like alert renderers)
- `env_action_group_id`, `env_dce_id`, `env_monitor_workspace_id`
  (passthrough, resolved by Stage 1 azapi lookup; Stage 2 consumes as
  tfvars so it doesn't redo the lookup)
- `aks_cluster_resource_id` (used for fetching cluster scope in role
  assignments; Stage 2's K8s API auth uses `aks_host` + CA + a
  workflow-minted AAD token, not this id)
- `tenant_id`, `subscription_id`

Stage 1 also creates an **`Azure Kubernetes Service RBAC Cluster Admin`**
role assignment on the AKS resource for the `fleet-<env>` UAMI so Stage 2
(running in the same workflow identity) can apply `kubernetes_*` /
`helm_release` resources using an AAD bearer token minted by the
workflow's OAuth2 client-assertion exchange.

Backend key: `{env}/{region}/{name}/stage1.tfstate`.

### Stage 2 — `terraform/stages/2-bootstrap`

Reads nothing from other stages' state and makes **zero Azure data
source calls at plan time**. All inputs arrive as tfvars materialized
from Stage 1 outputs by the workflow:

```bash
# In the cluster job, after Stage 1 apply:
terraform -chdir=terraform/stages/1-cluster output -json \
  | jq '{ (keys[]): .[keys[]].value }' \
  > "$RUNNER_TEMP/stage2.auto.tfvars.json"
cp "$RUNNER_TEMP/stage2.auto.tfvars.json" terraform/stages/2-bootstrap/
```

Stage 2 variables declared in `terraform/stages/2-bootstrap/variables.tf`
mirror the Stage 1 output schema 1:1; the tfvars file is gitignored and
lives only in `$RUNNER_TEMP` for the life of the job.

**Kubernetes / Helm provider authentication** — the Kubernetes and Helm
providers take `host`, `cluster_ca_certificate`, and `token` directly in
the provider block, so no kubeconfig file or `exec` block is needed.
Host and CA come from Stage 1 outputs via the tfvars file (they are
infrastructure facts). The AAD bearer token is **workflow-local**:
minted by a CI step that sits between the two Stage apply steps,
exported as `TF_VAR_aks_access_token`, declared `sensitive = true` in
Stage 2's `variables.tf`. The token is never a Stage 1 output, never
in a tfvars file on disk, never in TF state — just a direct env →
provider handoff at the workflow boundary.

The workflow does a plain OAuth2 client-assertion exchange against the
tenant's token endpoint using the job's GitHub OIDC JWT as the
assertion, with scope `6dae42f8-4368-4678-94ff-3960e28e3630/.default`
(the AKS AAD server app):

```bash
# Stage 1 outputs → Stage 2 tfvars (infrastructure values only):
terraform -chdir=terraform/stages/1-cluster output -json \
  | jq 'with_entries(.value |= .value)' \
  > "$RUNNER_TEMP/stage2.auto.tfvars.json"
cp "$RUNNER_TEMP/stage2.auto.tfvars.json" terraform/stages/2-bootstrap/

# Workflow-local AAD token → TF_VAR_aks_access_token (NOT a Stage 1 artifact):
gh_jwt=$(curl -sSL -H "Authorization: bearer $ACTIONS_ID_TOKEN_REQUEST_TOKEN" \
  "$ACTIONS_ID_TOKEN_REQUEST_URL&audience=api://AzureADTokenExchange" \
  | jq -r .value)
aks_token=$(curl -sSL -X POST \
  "https://login.microsoftonline.com/${AZURE_TENANT_ID}/oauth2/v2.0/token" \
  -d "client_id=${AZURE_CLIENT_ID}" \
  -d "scope=6dae42f8-4368-4678-94ff-3960e28e3630/.default" \
  -d "client_assertion_type=urn:ietf:params:oauth:client-assertion-type:jwt-bearer" \
  -d "client_assertion=${gh_jwt}" \
  -d "grant_type=client_credentials" | jq -r .access_token)
echo "::add-mask::$aks_token"
echo "TF_VAR_aks_access_token=$aks_token" >> "$GITHUB_ENV"
```

Stage 2 variables and providers:

```hcl
# variables.tf
variable "aks_host"                   { type = string }
variable "aks_cluster_ca_certificate" { type = string, sensitive = true }
variable "aks_access_token"           { type = string, sensitive = true }

# providers.tf
provider "kubernetes" {
  host                   = var.aks_host
  cluster_ca_certificate = base64decode(var.aks_cluster_ca_certificate)
  token                  = var.aks_access_token
}

provider "helm" {
  kubernetes = {
    host                   = var.aks_host
    cluster_ca_certificate = base64decode(var.aks_cluster_ca_certificate)
    token                  = var.aks_access_token
  }
}
```

The AAD token lifetime (~60 min default) comfortably covers any Stage 2
apply; if a future Stage 2 grows long enough to risk expiry, the
workflow can refresh by re-running the exchange before apply.

Auth works because Stage 1 already granted the `fleet-<env>` UAMI
`AKS RBAC Cluster Admin` on the cluster resource id.

Creates:

- `kubernetes_namespace.argocd` (ignore_changes on labels/annotations).
- `kubernetes_namespace.external_dns` + `ConfigMap external-dns-azure-config`
  (`azure.json` with workload-identity config pointing at
  `var.external_dns_identity_client_id`).
- `kubernetes_secret_v1.platform_identity` in the `argocd` namespace with
  keys `tenant_id`, `cluster_keyvault_name`, `fleet_keyvault_name`,
  `eso_client_id`, `external_dns_client_id`, and a
  `team_<name>_client_id` entry for every team on this cluster.
- `kubernetes_secret_v1.argocd_repo_creds_github` populated via an
  ephemeral KV read (azapi ephemeral resource performing a GET on
  `Microsoft.KeyVault/vaults/secrets/<name>` — the only azapi call in
  Stage 2, and it's ephemeral-only so no state leakage) and `data_wo`
  write-only attributes. Label `argocd.argoproj.io/secret-type: repo-creds`.
- Federated Identity Credentials (`azapi_resource`):
  - `fc-external-dns` → subject `system:serviceaccount:external-dns:external-dns`
  - `fc-eso` → subject `system:serviceaccount:external-secrets:external-secrets`
  - `fc-team-<team>` for each team, subject
    `system:serviceaccount:<team>-root:workload-identity`
  - **Conditional (`cluster.role == "management"`)**:
    `fc-kargo-mgmt` on the Stage 0-owned `uami-kargo-mgmt`
    (resource id from `var.kargo_mgmt_uami_resource_id`), subject
    `system:serviceaccount:kargo:kargo-controller`, issuer =
    `var.aks_oidc_issuer_url`. Binds the Kargo controller SA on the
    mgmt cluster to the fleet-wide Kargo UAMI; this is the only
    place the mgmt AKS OIDC issuer URL meets the Stage 0 UAMI
    identity, so it must happen here.
- **FICs on the Argo AAD app itself** (`azuread_application_federated_identity_credential`)
  scoped to this cluster:
  - name `argocd-<cluster-fqdn>`, issuer = `var.aks_oidc_issuer_url`,
    subject `system:serviceaccount:argocd:argocd-server`, audience
    `api://AzureADTokenExchange`. Lets Argo call AAD-protected APIs as
    the Argo app without a shared secret.
  - Removed automatically when the cluster is deprovisioned (TF
    destroy drops the FIC; the app itself and its redirect URIs
    survive).
- **Conditional (`cluster.role == "management"`)**: FICs on the **Kargo**
  AAD app for
  `system:serviceaccount:kargo:kargo-controller` and
  `system:serviceaccount:kargo:kargo-api`, same issuer/audience pattern.
- `helm_release.argocd` from `argo-cd` chart with values injecting a single
  bootstrap `Application` named `platform-root` pointing at
  `var.platform_gitops_repo_url` / `var.platform_gitops_path`. `lifecycle
{ ignore_changes = [values] }` so `30-argocd-self-manage.yaml` takes over.
- **Conditional (`cluster.role == "management"`)** `main.kargo.tf`:
  - `kubernetes_secret_v1.kargo_github_repo_creds` (data_wo PEM)
  - `kubernetes_secret_v1.kargo_oidc` (client id + secret from KV
    ephemeral)
  - Kargo itself is installed by Argo via `applications/25-kargo.yaml`;
    TF only seeds credentials.

Backend key: `{env}/{region}/{name}/stage2.tfstate`.

### Why two stages

Providers (`kubernetes`, `helm`) need values (host, CA, token) produced
when AKS exists. Running them in one apply forces `-target` or
`time_sleep` choreography and fights provider plan-time validation.

Independent state keys also keep a bootstrap rerun from touching
cluster infra. **Cross-stage values flow as tfvars materialized from
Stage 1 outputs inside one CI job** — not `terraform_remote_state`,
not Azure data sources. This keeps Stage 2 plan-time latency near zero
and makes "what Stage 2 sees" identical to "what Stage 1 just wrote",
by construction.

Trade-off accepted: Stage 2 cannot be applied in isolation without
first running a Stage 1 plan/apply (which no-ops if nothing changed).
In practice every CI invocation runs both legs, so this is a non-issue.

---

## 5. ArgoCD + Kargo bootstrap sequence

```
1. TF stage1 apply
   └─► AKS + identities + KV + DNS roles

2. TF stage2 apply
   └─► ArgoCD helm release; platform-root Application injected

3. ArgoCD begins syncing platform-gitops/applications/*:
   wave 00 ESO + ClusterSecretStores (azure-keyvault-cluster + azure-keyvault-fleet; both via workload identity)
   wave 10 external-dns, gateway, tls-wildcard
   wave 20 observability
   wave 25 kargo            (ApplicationSet cluster-generator filtered to role=management)
   wave 30 argocd-self-manage (adopts the Helm release; TF steps back)
   wave 40 teams            (ApplicationSet matrix over teams × opted-in clusters)

4. On the management cluster only:
   Kargo comes up, loads:
     - GitHub App repo-creds (from TF-seeded secret, adopted by ESO thereafter)
     - OIDC SSO (reusing Argo's AAD tenant)
     - Projects, Warehouses, Stages, PromotionTemplates
       (synced by Argo from platform-gitops/kargo/)
```

Every workload cluster runs its own ArgoCD and watches the same
`platform-gitops` repo. Kargo mutates per-env `values.yaml` files; each
cluster's ArgoCD picks up whichever env overlay matches its
`cluster.env` label.

---

## 6. Platform promotion model (Kargo)

Every Kargo-promoted platform component has overlays:

```
platform-gitops/components/<component>/
├── base/values.yaml
└── environments/
    ├── dev/values.yaml         # written by dev Stage
    ├── staging/values.yaml     # written by staging Stage
    └── prod/values.yaml        # opened as PR by prod Stage
```

Each platform component's Argo Application is rendered per cluster by an
ApplicationSet cluster-generator that resolves `valueFiles` to
`[base/values.yaml, environments/<cluster.env>/values.yaml]`.

Per component, Kargo carries:

- **Warehouse** — subscribes to the Helm chart OCI repo (and optionally the
  git path for companion manifests).
- **Stages** — `platform-<component>-dev`, `-staging`, `-prod`.
  - `dev` auto-promotes new Freight; PromotionTemplate
    `platform-nonprod.yaml` writes `environments/dev/values.yaml` and commits
    directly to `main`.
  - `staging` is manual; same template; direct commit.
  - `prod` is manual; PromotionTemplate `platform-prod.yaml` opens a PR to
    `main`.
- **Verification** — `verification.argocdApps` resolves (via label selector
  keyed on `cluster.env`) to every Argo App rendered from this component
  across the fleet. Kargo blocks promotion until all are Healthy/Synced.

Kargo self-manages through its own pipeline; initial install version is
pinned by `25-kargo.yaml`'s values file.

Components to onboard in Phase 5: `argocd-self-manage`, `eso`,
`external-dns`, `gateway`, `tls-wildcard`, `observability`, `kargo`.

---

## 7. Team tenancy — rendered per-team by `components/teams`

Source: `platform-gitops/config/teams/<team>.yaml`.

**Team identity is derived, not declared.** The team name equals the
file's basename (without `.yaml`); the namespace prefix equals the
team name. Neither field appears in the YAML — filesystem uniqueness
is the sole guarantee of name uniqueness, and prefix collisions are
impossible because the prefix is a pure function of the filename.
The filename must match `^[a-z0-9]([a-z0-9-]{0,61}[a-z0-9])?$` (DNS
label rules) so it doubles as a legal Kubernetes namespace prefix.

```yaml
# File: platform-gitops/config/teams/team-a.yaml
#   → team name:        team-a          (derived from filename)
#   → namespace prefix: team-a          (= team name)
#   → AppProject glob:  team-a-*        (= prefix + "-*")

oidcGroup: aad-group-team-a
repo:
  url: https://github.com/acme/team-a-gitops
  appPath: services # services/<app>/environments/<env>/values.yaml
# sharedChartRepo is fleet-wide (the ACR from Stage 0); not declared per team.
services: # list required for Kargo warehouse generation
  - name: api
    imageRepo: acmefleet.azurecr.io/team-a/api # fleet ACR path
  - name: worker
    imageRepo: acmefleet.azurecr.io/team-a/worker
clusters: # opt-in; matches clusters/<env>/<region>/<name> path
  - nonprod/eastus/aks-nonprod-01
  - prod/eastus/aks-prod-01
```

**Static validation** (enforced in `validate.yaml`, see §10):

- Filename matches the regex above; `yq` check that no file contains a
  top-level `name:` or `namespacePrefix:` key (guards against operators
  re-introducing collision surfaces out of habit).
- `oidcGroup` is unique across all `teams/*.yaml` — a duplicate means
  two AppProjects share an admin population, almost always a config
  mistake; this is hard-failed at PR time.
- `services[].name` unique within a file.
- `services[].imageRepo` starts with `${ACR_LOGIN_SERVER}/` (the fleet
  ACR — Kargo Warehouses cannot subscribe to arbitrary external
  registries in the default architecture).
- Every `clusters[]` entry resolves to an existing
  `clusters/<env>/<region>/<name>/cluster.yaml`.

`40-teams.yaml` is an ApplicationSet using a **matrix** of:

1. a git-files generator over `platform-gitops/config/teams/*.yaml`,
2. an Argo cluster generator (every registered cluster).

The ApplicationSet template extracts `<team>` from the file path
(`path.basenameNormalized`) — the YAML body does not carry the name
back in. An `exclude`/`selector` template keeps only combinations
where the team's `clusters:` list contains the current cluster's
`<env>/<region>/<name>` label. For each surviving combination, a
single Argo Application is rendered, pointing at
`platform-gitops/components/teams` with per-team and per-cluster
values.

`components/teams` (Helm chart `team-resources`) renders **per team ×
per cluster**:

1. **AppProject `<team>`** (name from filename)
   - `sourceRepos`: `<team.repo.url>`, the fleet ACR OCI path
     (`<acr>.azurecr.io/helm/*`), and the fleet repo (so its own
     ApplicationSet can pull values).
   - `destinations`: `{ server: https://kubernetes.default.svc, namespace: "<team>-*" }`.
   - `clusterResourceWhitelist`: `Namespace` only.
   - `namespaceResourceBlacklist`: `ResourceQuota`, `LimitRange`,
     `NetworkPolicy`.
   - `roles[0]` — `role/admin` mapped to `<team.oidcGroup>`.
2. **Namespace `<team>-root`** + ServiceAccount `workload-identity`
   annotated with the team's `client-id` from the `platform-identity`
   secret.
3. **ApplicationSet `<team>-services`** — git-directory generator over
   `<team.repo.url>/<appPath>/*`. Each service emits one Argo App per
   the current cluster's `env` overlay:
   - `source.helm.valueFiles: [base/values.yaml, environments/<cluster.env>/values.yaml]`
   - `destination.namespace: "<team>-<app>"` (enforced by the
     AppProject destination glob).
   - `project: <team>`.
4. **Kargo Project `<team>`** with RBAC binding `<team.oidcGroup>` →
   `role/admin`.
5. **Kargo Warehouses** — one per entry in `services:`. Subscribes to
   the container image and the team repo.
6. **Kargo Stages** `<team>-<service>-{dev,staging,prod}`.
   - `dev`: auto; PromotionTemplate `team-nonprod.yaml` writes
     `services/<service>/environments/dev/values.yaml` in the team repo,
     direct commit.
   - `staging`: manual; same template; direct commit; verification checks
     `dev` Apps are Healthy.
   - `prod`: manual; PromotionTemplate `team-prod.yaml` opens a PR to
     `main` on the team repo; verification checks `staging` Apps are
     Healthy.

Namespace prefix wildcard enforcement happens exclusively at the
AppProject destination glob; teams may create as many Applications as
they like provided their namespaces start with `<team>-`.

---

## 8. Secrets & identity

- **ArgoCD GitHub App** (already in inspiration): `contents: read`
  installation on fleet repo + team repos; PEM in **fleet KV**
  (read by every cluster's Argo); TF Stage 2 seeds
  `argocd-repo-creds` via ephemeral `data_wo` on each cluster.
- **Kargo GitHub App** (new, separate identity): `contents: write`,
  `pull-requests: write` on fleet repo + team repos. PEM in the
  **mgmt cluster's KV** (only the mgmt cluster runs Kargo). TF
  Stage 2 on the management cluster seeds the initial
  `kargo-github-repo-creds` secret via `data_wo`; ESO on mgmt then
  owns ongoing rotation of the same secret.
- **Kargo OIDC client**: same Azure AD tenant as Argo (separate
  app registration in Stage 0). Client secret generated and stored
  in the **mgmt cluster KV** (Stage 1, not fleet KV); ESO on mgmt
  syncs it into the `kargo` namespace.
- **Image registry credentials** — the fleet ACR is pulled via
  **AcrPull role assignment on each cluster's kubelet identity** (no
  image-pull secrets). Kargo Warehouses that subscribe to ACR images
  authenticate as the **single fleet-wide `uami-kargo-mgmt`
  identity** (Stage 0), which carries two role assignments in total:
  (1) `AcrPull` on the fleet ACR, granted in Stage 0; (2)
  `AKS RBAC Reader` on every workload AKS cluster, granted in that
  workload cluster's Stage 1. This consolidation is required because
  Azure Workload Identity annotates a single K8s ServiceAccount with
  exactly one `client-id` — the Kargo controller SA
  (`system:serviceaccount:kargo:kargo-controller`) can therefore
  federate to exactly one UAMI. The FIC binding that SA to
  `uami-kargo-mgmt` is created in the mgmt cluster's Stage 2
  (`fc-kargo-mgmt`). No separate `uami-kargo-acr` identity exists.
- **Workload Identity** via FICs seeded in TF Stage 2 for external-dns,
  eso, and one per team (team FIC subject
  `system:serviceaccount:<team>-root:workload-identity`).

---

## 9. RBAC

- A team's `oidcGroup` drives both:
  - Argo AppProject `role/admin` (`p, proj:<team>:admin, applications, *, <team>/*, allow`).
  - Kargo Project `role/admin` (`promote`, `verify`, `view` on all Stages
    in the Project).
- Platform-admin group is granted `*, *` in Argo and `*, *` in Kargo.
- Team admins cannot edit Warehouses/Stages — those are declared in the
  fleet repo and synced by Argo, so direct edits are rejected.

---

## 10. CI/CD

### Runner selection

Every workflow that writes to Terraform state — `env-bootstrap.yaml`,
`team-bootstrap.yaml`, `tf-plan.yaml`, `tf-apply.yaml`, `stage0.yaml`, and
the (deferred) `fleet-bootstrap-rerun.yaml` — **must** use
`runs-on: [self-hosted]`. The fleet tfstate SA and the fleet KV are
private-only; GitHub-hosted runners cannot reach them. The self-hosted
runner pool is the single pool created by `bootstrap/fleet` (§4 Stage -1,
"Runner infrastructure").

Template-level workflows that do **not** touch tfstate — `validate.yaml`,
`tflint.yaml`, `template-selftest.yaml`, `status-check.yaml` — stay on
`runs-on: ubuntu-latest`. They are deleted from adopter repos by
`init-fleet.sh` anyway.

### Workflows

- **`validate.yaml`** (`pull_request`):
  - `terraform fmt -check -recursive`
  - `tflint` per module / stage
  - `yamllint` over `clusters/` and `platform-gitops/config/`
  - JSON-schema validation of merged `cluster.yaml` and `teams/*.yaml`
  - **Team-config linter** (`.github/scripts/lint-teams.sh`): for
    every `platform-gitops/config/teams/*.yaml`:
    1. filename matches `^[a-z0-9]([a-z0-9-]{0,61}[a-z0-9])?\.yaml$`
       (DNS-label rules; doubles as a legal namespace prefix);
    2. file does **not** contain top-level `name:` or
       `namespacePrefix:` keys (guards against operators
       re-introducing the derived fields out of habit — hard
       failure with a message pointing at §7);
    3. `oidcGroup` values are unique across the whole directory —
       duplicate = hard failure;
    4. `services[].name` unique within each file;
    5. every `services[].imageRepo` starts with `${ACR_LOGIN_SERVER}/`
       (the fleet ACR — Warehouses cannot subscribe to arbitrary
       external registries in the default architecture);
    6. every `clusters[]` path resolves to an existing
       `clusters/<env>/<region>/<name>/cluster.yaml`.
  - `helm lint` on `platform-gitops/components/*`
  - `kargo lint` on `platform-gitops/kargo/**`

- **`env-bootstrap.yaml`** (`workflow_dispatch`, inputs: `env`):
  1. `environment: fleet-meta` — 2-reviewer gate.
  2. OIDC-auth as `fleet-meta` UAMI.
  3. `terraform -chdir=terraform/bootstrap/environment apply -var env=<input>`.
  4. Comment summary on the triggering run with created resource IDs.

- **`team-bootstrap.yaml`** (`push` to `main`, path filter
  `platform-gitops/config/teams/*.yaml`):
  1. Detects newly-added team YAMLs only (diff against previous main).
  2. Derives team name from the filename basename (no `name:` field
     exists in the file to read).
  3. `environment: fleet-meta`.
  4. For each new team, `terraform -chdir=terraform/bootstrap/team apply -var team=<derived-name>`.
  5. Creates team repo + branch protection + Kargo GH App install.

- **`tf-plan.yaml`** (`pull_request`):
  1. Change detection: `git diff --name-only origin/main...HEAD` under
     `clusters/` and `terraform/stages/`.
  2. For each affected cluster, run `config-loader/load.sh` →
     `terraform.tfvars.json` for Stage 1 and Stage 2; one matrix leg per
     affected cluster; `environment: fleet-<cluster.env>` (derived from
     the path).
  3. If `terraform/stages/0-fleet/**` changed, a separate matrix leg
     runs Stage 0 plan under `environment: fleet-stage0`.
  4. Post a consolidated plan summary as a single PR comment.

- **`tf-apply.yaml`** (`push` to `main`):
  1. Same change detection, same environment mapping.
  2. Stage 0 leg (if any) runs first and serially.
  3. Post-Stage-0 step publishes outputs to repo variables
     (`ACR_LOGIN_SERVER`, `ACR_RESOURCE_ID`, `FLEET_KEYVAULT_ID`,
     `FLEET_KEYVAULT_NAME`, `ARGOCD_AAD_APPLICATION_ID`,
     `KARGO_AAD_APPLICATION_ID`) using the `stage0-publisher` GH App.
     Per-env obs outputs (`MONITOR_WORKSPACE_*_<ENV>`, `GRAFANA_*_<ENV>`,
     `ACTION_GROUP_ID_<ENV>`) are published by `env-bootstrap.yaml`
     into each env's GitHub environment, not here.
  4. Cluster legs run after Stage 0: per cluster, a **single job** runs
     Stage 1 apply → pipe outputs to Stage 2 tfvars → mint AAD token
     into `TF_VAR_aks_access_token` → Stage 2 apply. Sequential within
     the job; `prod/*` matrix serialized (`max-parallel: 1`).

     ```yaml
     - name: Stage 1 apply
       run: terraform -chdir=terraform/stages/1-cluster apply -auto-approve -var-file=$TFVARS
     - name: Stage 1 outputs → Stage 2 tfvars
       run: |
         terraform -chdir=terraform/stages/1-cluster output -json \
           | jq 'with_entries(.value |= .value)' \
           > "$RUNNER_TEMP/stage2.auto.tfvars.json"
         cp "$RUNNER_TEMP/stage2.auto.tfvars.json" terraform/stages/2-bootstrap/
     - name: Mint AAD token → TF_VAR_aks_access_token
       run: .github/scripts/mint-aks-token.sh # the curl/jq recipe in §4 Stage 2
     - name: Stage 2 apply
       run: terraform -chdir=terraform/stages/2-bootstrap apply -auto-approve
     ```

     `stage2.auto.tfvars.json` holds Stage 1 infra outputs (CA marked
     `sensitive`). The AAD token flows via env var `TF_VAR_aks_access_token`
     (masked with `::add-mask::`) straight into Stage 2's `sensitive`
     variable — never written to disk, never in TF state.
  5. Summary posted back to the merged PR.

### Azure authentication

**Per-environment GitHub OIDC federation** into dedicated UAMIs. No
long-lived cloud secrets in Actions. Identities:

| Identity            | Created by              | Used by                                  | Scope                                                                                                                                                                                                                                                             |
| ------------------- | ----------------------- | ---------------------------------------- | ----------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| `fleet-stage0` UAMI | `bootstrap/fleet`       | Stage 0 matrix leg                       | `rg-fleet-shared` Contributor + `tfstate-fleet` Blob Contributor + Entra AppAdmin                                                                                                                                                                                 |
| `fleet-meta` UAMI   | `bootstrap/fleet`       | env-bootstrap + team-bootstrap workflows | Tenant/subscription-wide UAccessAdmin + Contributor                                                                                                                                                                                                               |
| `fleet-<env>` UAMI  | `bootstrap/environment` | Stage 1 + Stage 2 matrix legs            | env subscription/RG Contributor + `tfstate-<env>` Blob Contributor + fleet KV Secrets User + ACR UAccessAdmin + `User Access Administrator` scoped to the env AMW resource id (to delegate `Monitoring Metrics Publisher` to cluster addon identities in Stage 1) |

Stage 1 **consumes Stage 0 outputs via repo variables**
(`vars.ACR_RESOURCE_ID`, `vars.FLEET_KEYVAULT_ID`, etc.) rather than
`terraform_remote_state`. This removes Stage 1's need to read the
`tfstate-fleet` container and keeps stage boundaries clean.

### GitHub environments

| Environment     | Reviewers | Purpose                          |
| --------------- | --------- | -------------------------------- |
| `fleet-stage0`  | 0         | Stage 0 runs                     |
| `fleet-meta`    | 2         | Bootstrap workflows (env + team) |
| `fleet-mgmt`    | 1         | Mgmt cluster apply               |
| `fleet-nonprod` | 0         | Nonprod cluster apply            |
| `fleet-prod`    | 2         | Prod cluster apply               |

Each environment holds its own `AZURE_CLIENT_ID` / `AZURE_TENANT_ID` /
`AZURE_SUBSCRIPTION_ID` variables; workflows never hard-code them.

### Terraform backend

- Single Azure Storage account `tfstate-fleet` (created by
  `bootstrap/fleet`). Multiple containers inside:
  - `tfstate-fleet` — Stage 0 + bootstrap/environment + bootstrap/team
  - `tfstate-<env>` — per-env Stage 1 + Stage 2 (created by
    `bootstrap/environment` for that env).
- State key within each container:
  - Stage 0: `stage0/fleet.tfstate`
  - Stage 1: `{region}/{name}/stage1.tfstate`
  - Stage 2: `{region}/{name}/stage2.tfstate`
  - Bootstrap roots: `bootstrap/<root>/<key>.tfstate`

### Path filters

- `tf-plan.yaml` / `tf-apply.yaml` watch `clusters/**`,
  `terraform/stages/**`, `.github/workflows/**`.
- `env-bootstrap.yaml` is `workflow_dispatch` only (ignores paths).
- `team-bootstrap.yaml` watches `platform-gitops/config/teams/**`.
- `platform-gitops/**` never triggers Terraform; Kargo commits to that
  path do not trigger CI beyond lint checks.

### Branch protection

`main`-branch protection on the fleet repo and the team-template repo
is enforced via GitHub repository **rulesets** (vendored
`terraform/modules/github-repo/modules/ruleset`), not the legacy
`github_branch_protection` resource. The ruleset requires signed
commits, PR review (1 approver, CODEOWNERS), up-to-date branches, and
a `validate` status check; non-fast-forward pushes are blocked.
Kargo-bot bypass on
`platform-gitops/components/*/environments/{dev,staging}/values.yaml`
is deferred until the Kargo GitHub App is minted (see §15).

- `main` requires PR review, `validate.yaml` to pass, signed commits.
- Exception for the Kargo GitHub App on paths
  `platform-gitops/components/*/environments/{dev,staging}/values.yaml`
  (direct pushes allowed). Prod promotions are always PRs and go through
  normal review.

### Drift detection

- Nightly workflow runs `terraform plan` across all clusters; opens an
  issue on non-empty diff.

---

## 11. Operator UX

### Onboard a cluster

1. `cp -r clusters/_template clusters/<env>/<region>/<name>/`.
2. Fill `cluster.yaml`: `env`, `role`, `region`, IDs, `teams:`.
3. Create `platform-gitops/config/clusters/<env>-<region>-<name>.yaml`
   with matching labels so ApplicationSets can target it.
4. Open PR → review plan → merge.
5. CI runs Stage 1 then Stage 2. Argo takes over; verify platform Apps
   Healthy/Synced.

### Onboard a team

1. Create `platform-gitops/config/teams/<team>.yaml`.
2. Add `<team>` to the `teams:` list in every cluster `cluster.yaml` the
   team should deploy to (drives Stage 1 UAMI/FIC creation).
3. Merge. Stage 1 creates the UAMI; Stage 2 extends the
   `platform-identity` secret and creates the FIC. Argo renders the
   AppProject, ApplicationSet, Kargo Project, Warehouses, and Stages.
4. Team creates `services/<app>/environments/{dev,staging,prod}/values.yaml`
   in their repo with a placeholder image tag.
5. First image push → Kargo Warehouse produces Freight → `dev` Stage
   auto-promotes.
6. Team promotes `dev → staging` (direct commit) and `staging → prod` (PR)
   from the Kargo UI.

### Upgrade Kubernetes on a cluster

1. Edit `kubernetes.version` in `cluster.yaml`.
2. PR → plan shows AKS control-plane + node-pool version diff.
3. Review / approve; merge.
4. CI runs Stage 1 apply for that cluster only. AKS rolls nodes. Stage 2
   runs with no changes.

### Upgrade a platform component

1. Chart publisher ships a new version.
2. Kargo Warehouse discovers it → Freight created.
3. `dev` Stage auto-promotes → commit to
   `components/<comp>/environments/dev/values.yaml`.
4. Argo syncs `env=dev` clusters; Kargo verification waits on App health.
5. Platform admin promotes `dev → staging` in Kargo UI; direct commit.
6. After staging bakes, promote `staging → prod`; Kargo opens a PR;
   reviewers merge; Argo syncs prod clusters.

---

## 12. Risks and mitigations

| Risk                                                                 | Mitigation                                                                                                                                                |
| -------------------------------------------------------------------- | --------------------------------------------------------------------------------------------------------------------------------------------------------- |
| Management cluster is a SPOF for promotion.                          | Same cluster shape as workload clusters; Velero backup of Kargo namespace; Argo on workload clusters keeps syncing last-committed state if Kargo is down. |
| ApplicationSet matrix explosion at scale (>15 clusters × >50 teams). | Stay on matrix for Phase 6; switch to cluster + list generator (cluster Secret annotation driven by TF Stage 2) if reconcile exceeds ~30 s.               |
| Kargo bot commits bad YAML.                                          | `helm template`/`kubeval` step in `validate.yaml` runs on `platform-gitops/**`; prod is always gated by PR review by design.                              |
| Kargo self-upgrade bricks itself.                                    | Prod promotion of Kargo is PR-only; documented `helm rollback` runbook on the mgmt cluster.                                                               |
| Team repo contract drift (`environments/<env>/values.yaml` missing). | Publish cookiecutter team-repo template; Kargo warehouse health surfaces missing paths; team ApplicationSet tolerates empty list gracefully.              |
| Direct-to-main bot commits forbidden by org policy.                  | Flip all PromotionTemplates to PR mode and accept added latency.                                                                                          |
| `helm_release` with `ignore_changes=[values]` drifts from TF view.   | Treat Argo as source of truth for component versions post-bootstrap; TF plans remain clean.                                                               |
| Bumping `kubernetes.version` across many prod clusters concurrently. | CI apply matrix caps `prod/*` at `max-parallel: 1`; environments gate approval per cluster.                                                               |

---

## 13. Phased implementation

### Phase 1 — Skeleton

- Repo scaffold per §2.
- `_defaults.yaml` at fleet level; `_fleet.yaml` with ACR name + fleet
  KV name + AAD app display names + DNS root.
- `terraform/bootstrap/fleet` — human runs locally with tenant-admin
  credentials. Produces: fleet TF state SA (private endpoint),
  **fleet Key Vault (private endpoint)**, `uami-fleet-runners` UAMI +
  `Key Vault Secrets User` role assignment on the fleet KV,
  shared self-hosted GH Actions runner pool (ACA+KEDA) + per-pool
  ACR + LAW, `fleet-stage0` + `fleet-meta` UAMIs (plus
  `Key Vault Secrets Officer` on the fleet KV for `fleet-stage0`),
  `fleet-meta` + `stage0-publisher` + `fleet-runners` GH Apps,
  `fleet-stage0` + `fleet-meta` GH environments, team-repo template
  repo, branch protection on fleet repo.
- `terraform/bootstrap/environment` — invoked via `env-bootstrap.yaml`
  for `mgmt` and `nonprod`. Produces: per-env state container, UAMI,
  GH environment + variables, env-root resource groups.
- One mgmt cluster (`clusters/mgmt/eastus/aks-mgmt-01`, 2× D4s_v5
  system pool only, autoscaler 2–4) and one nonprod cluster
  (`clusters/nonprod/eastus/aks-nonprod-01`, system + apps pools).
- `terraform/stages/0-fleet` applied via CI (under `fleet-stage0`);
  outputs auto-published to repo variables.
- `terraform/modules/aks-cluster` (wrapping AVM
  `avm-res-containerservice-managedcluster/azurerm`) and
  `terraform/stages/1-cluster` complete, including cluster KV
  creation, private DNS zone + VNet links, and AcrPull role
  assignment. Stage 1 consumes Stage 0 outputs via repo variables.
- `terraform/config-loader/load.sh`.
- `validate.yaml`, `tf-plan.yaml`, `tf-apply.yaml`, `env-bootstrap.yaml`
  minimally functional.
- Exit criterion: bootstrap flows produce working CI credentials;
  Stage 0 applies; both clusters provision and can pull from the
  fleet ACR.

### Phase 2 — ArgoCD bootstrap

- `terraform/modules/argocd-bootstrap` and `terraform/stages/2-bootstrap`.
- `platform-gitops/applications/30-argocd-self-manage.yaml` and
  `platform-gitops/components/argocd-self-manage/`.
- `platform-gitops/applications/00-eso.yaml` and
  `components/eso/`; two ClusterSecretStores using workload identity —
  `azure-keyvault-cluster` (points at this cluster's KV) and
  `azure-keyvault-fleet` (points at the fleet KV). Team ExternalSecrets
  default to the cluster store; platform ExternalSecrets that pull
  fleet-wide secrets explicitly reference the fleet store.
- Exit criterion: on both clusters, ArgoCD is up, ESO reads from Key
  Vault, `argocd-self-manage` has adopted the Helm release.

### Phase 3 — Platform services (pre-Kargo)

- external-dns (including TF Stage 1 DNS role assignments, FIC, and
  `azure.json` ConfigMap).
- gateway, tls-wildcard, observability.
  - **Observability** here is the in-cluster layer only: Grafana
    Agent (or `ama-metrics` addon tuning via ConfigMap), kube-state
    scraping overrides, alert-routing CRDs. The AMW + Grafana backend
    are already provisioned by Stage 0; per-cluster DCR/DCRA is
    provisioned by Stage 1. The component's job is to point workloads
    at `MONITOR_WORKSPACE_QUERY_ENDPOINT` and surface cluster-scope
    `PrometheusRule` CRDs that the TF-managed
    `Microsoft.AlertsManagement/prometheusRuleGroups` cannot express.
- At this phase components are single-file (no overlays yet).
- Exit criterion: a sample HTTPRoute resolves via external-dns with a
  valid TLS cert on a workload cluster.

### Phase 4 — Kargo install

- `applications/25-kargo.yaml` with cluster-generator filter
  `platform.example.com/role=management`.
- `components/kargo/` chart values.
- TF Stage 2 `main.kargo.tf` seeds Kargo GitHub App repo-creds and OIDC
  secrets on the mgmt cluster.
- One dummy platform Warehouse/Stage/PromotionTemplate proves end-to-end
  promotion on a trivial chart.
- Exit criterion: Kargo UI reachable, OIDC SSO works, a dummy promotion
  mutates a values file and Argo syncs it.

### Phase 5 — Platform promotion rollout

- Convert each platform component to env overlays under
  `components/<comp>/environments/{dev,staging,prod}/values.yaml`.
- Convert each `applications/*.yaml` to an ApplicationSet cluster
  generator resolving `valueFiles` by `cluster.env`.
- Add Warehouses, Stages, PromotionTemplates for all platform components.
- Exit criterion: a chart version bump flows dev → staging → prod across
  the fleet via Kargo.

### Phase 6 — Team tenancy + team promotion

- `components/teams` Helm chart with all template resources in §7
  (namespace, SA, AppProject, ApplicationSet, Kargo Project, Warehouses,
  Stages).
- `applications/40-teams.yaml` ApplicationSet (matrix, with team+cluster
  filter).
- TF Stage 1 per-team UAMI creation; Stage 2 per-team FIC and extension
  of `platform-identity` secret.
- Example `team-a` registry entry + example team repo demonstrating
  `services/api/environments/*/values.yaml`.
- Exit criterion: pushing a new image for team-a's `api` flows
  dev → staging → prod end-to-end across opted-in clusters.

### Phase 7 — Hardening

- Nightly drift detection workflow.
- Cookiecutter team-repo template repo.
- Velero install on the mgmt cluster covering Kargo and ArgoCD state.
- Runbooks in `docs/`: `upgrades.md`, `promotion.md`,
  `onboarding-cluster.md`, `onboarding-team.md`.
- PR-plan matrix performance tuning: `max-parallel` caps, prod
  serialization, caching of terraform providers.
- Schema validation rolled into `validate.yaml` for `cluster.yaml` and
  team registry files.

---

## 14. Resolved Phase-1 configuration

- **AKS module**: `Azure/avm-res-containerservice-managedcluster/azurerm`,
  version pin added in `terraform/modules/aks-cluster/main.tf` (select
  latest `>= 0.1` at scaffold time).
- **Container registry**: one ACR per fleet, Premium SKU, hosts OCI
  images under `<team>/<image>` and Helm charts under `helm/<chart>`.
  Created in Stage 0. Kubelet identity on every cluster gets `AcrPull`.
- **Key Vaults**: two-tier.
  - **Fleet KV** (`kv-<fleet.name>-fleet`) created by `bootstrap/fleet`
    (Stage -1, alongside the tfstate SA and runner pool — co-located
    to break the runner-pool KV-reference deploy-time cycle). Strictly
    private: `publicNetworkAccess = Disabled`,
    `networkAcls.defaultAction = Deny`, private endpoint on the
    derived `snet-pe-fleet` subnet registering into the central
    `privatelink.vaultcore.azure.net` zone. Stores GH App PEMs
    (Argo, fleet-meta, stage0-publisher, fleet-runners) and AAD
    OIDC client secrets. Secret seeding and rotation are Stage 0's
    responsibility (it holds `Key Vault Secrets Officer` on the
    vault). One instance for the whole fleet.
  - **Cluster KV** (`kv-<cluster.name>`) created by Stage 1; one per
    cluster; stores cluster-local secrets (TLS wildcard, observability
    keys, team-owned app secrets). ESO on each cluster binds via
    workload identity to both — primary store is the cluster KV;
    fleet KV is used only for fleet-wide secrets.
- **AAD app registrations**: Argo OIDC client and Kargo OIDC client
  managed by Terraform in Stage 0; redirect URIs appended per cluster in
  Stage 1. See §4 / Stage 0.
- **Management cluster sizing**: 2× `Standard_D4s_v5` in the system
  pool; **no apps pool**. All platform + Kargo workloads tolerate the
  system pool (ArgoCD, Kargo, ESO, external-dns). Autoscaler range 2–4.
- **Node autoscaler**: enabled on every node pool of every cluster via
  `min_count` / `max_count`; cluster-wide autoscaler profile tunables
  live in `kubernetes.cluster_autoscaler_profile` with fleet defaults in
  `clusters/_defaults.yaml`.
- **Subscription model**: one subscription per environment
  (`sub-fleet-shared`, `sub-fleet-mgmt`, `sub-fleet-nonprod`,
  `sub-fleet-prod`). Each per-env UAMI receives `Contributor` at
  subscription scope. Subscription IDs are surfaced in each GH
  environment's variables.
- **Entra role for bootstrap UAMIs**: `Application Administrator`
  assigned to both `fleet-stage0` and `fleet-meta` UAMIs.
- **VNets**: repo-owned per §3.4. Mgmt VNet (N=1) created by
  `bootstrap/fleet` via `Azure/avm-ptn-alz-sub-vending/azure`; env
  VNets (one per env-per-region) created by `bootstrap/environment`
  via the same module with intra-env mesh. Env↔mgmt peerings
  authored by `bootstrap/environment` via
  `Azure/avm-res-network-virtualnetwork/azurerm//modules/peering` with
  `create_reverse_peering` honoured per env-region. Adopter-owned
  hub VNets referenced by resource id from
  `_fleet.yaml.networking.envs.<env>.regions.<region>.hub_network_resource_id`
  only — not provisioned by this repo.

## 15. Remaining open items (deferred)

- Exact Premium SKU geo-replication regions for the ACR (start with
  single-region; add replicas when a second region onboards).
- Whether mgmt cluster should be private (defaults to yes, aligned with
  workload clusters).
- Node pool canary shape for Phase-7 staged upgrades.
- Cost-tagging standard (fleet-wide tag schema to apply across all
  Azure resources).
- **NSP preview status** — `Microsoft.Network/networkSecurityPerimeters`
  is in preview in several Azure regions. Pin to a preview API version
  (e.g. `2023-08-01-preview`) in the `azapi` provider block and verify
  availability in each env's region before running
  `env-bootstrap.yaml`. Fallback if NSP is not GA in a chosen region:
  switch to AMPLS for AMW/DCE private ingestion and a Grafana PE only
  (Grafana→AMW over AMPLS). This doesn't change Stage 1 contracts.
- **NSP inbound rule rotation** — if Grafana's subscription ever
  changes, or a break-glass IP allowlist is introduced, the
  `allow-grafana-query` rule needs updating in `bootstrap/environment`.
  Not automated today.
- **Kargo cross-cluster verification mechanism** — in the federated-Argo
  model each cluster runs its own ArgoCD. Kargo on mgmt needs to check
  `Application` health on workload clusters; the plan grants the Kargo
  UAMI `AKS RBAC Reader` on each workload cluster so it can read
  `Application` CRs via the K8s API. Whether Kargo's built-in Argo CD
  verification step supports this (querying multiple clusters by K8s
  API rather than a single Argo API endpoint) needs validation during
  Phase 4. Fallback: custom Kargo `AnalysisTemplate` that shells out to
  `kubectl --kubeconfig=<generated from workload identity> get application`.
- **Residual Argo/Kargo OIDC RP `client_secret`** — the only long-lived
  shared secrets in the fleet. Argo CD (via Dex or native OIDC) and
  Kargo authenticate to the AAD token endpoint as confidential OIDC
  relying parties using `client_secret` in the auth-code exchange.
  Azure supports secret-less RP auth via `private_key_jwt` /
  `client_assertion` (including FIC-style external-JWT assertions),
  but neither Argo CD, Dex, nor Kargo implement `client_assertion` RP
  authentication upstream today. Mitigation in Stage 0: short TTL
  (90d), TF-driven rotation via `azuread_application_password` +
  `time_rotating` keeper (60-day cadence, create-before-destroy so
  the live secret stays valid through the rotation window), store
  only in fleet KV, reflect to cluster via ESO, reload-on-change in
  Argo/Kargo.
  **Removal trigger**: when upstream (Argo CD or Dex) ships
  `client_assertion` support, delete the
  `azuread_application_password` resource and rely solely on the
  per-cluster `azuread_application_federated_identity_credential`
  resources that already exist for the workload→AAD direction —
  same pattern, now covering RP auth too — and delete the fleet KV
  entry.
- **`fleet-bootstrap-rerun.yaml` workflow** — `bootstrap/fleet` is
  run locally today (§4 Stage -1). Moving it to a self-hosted runner
  in CI would require a fourth privileged UAMI with Entra
  **Privileged Role Administrator** (to self-assign the
  `Application Administrator` role onto `fleet-stage0` /
  `fleet-meta` on subsequent runs), plus a `bootstrap/fleet`-scoped
  GH App / OIDC FIC. Trade-off: strictly more standing privilege
  than the current "run locally once" model. Deferred until the
  operator UX demand justifies the extra privileged identity.
- **AKS agent-pool ASG API-version confirmation (§3.4)** — the
  pinned `Azure/avm-res-containerservice-managedcluster/azurerm`
  version must expose `networkProfile.applicationSecurityGroups` on
  agent pools for the node-ASG attachment pattern to work directly.
  To verify at implementation time; fallback is Stage 1 authoring
  NSG rules on `nsg-pe-env-<env>-<region>` with cross-stage
  `Network Contributor` pre-granted by `bootstrap/environment`.
- **AVM module version pins for networking** — exact `~> X.Y`
  constraints for `Azure/avm-ptn-alz-sub-vending/azure` and
  `Azure/avm-res-network-virtualnetwork/azurerm//modules/peering`
  to be selected at implementation time (latest satisfying
  `azapi ~> 2.5`, `enable_telemetry = false`).

## 16. Template-repo adoption model

This repo ships as a **GitHub template repository**. Adopters instantiate
their own fleet repo via GitHub's "Use this template" flow, then run a
one-shot initializer to materialize adopter-specific values. After
initialization the repo is a concrete, self-contained fleet repo with
no template machinery left behind.

The rendering layer is a **throwaway Terraform root module at `init/`**
driven by a thin wrapper shell (`init-fleet.sh`). Terraform is already
a hard dependency for bootstrap, and `templatefile()` plus variable
validation blocks give us typed inputs and per-field regex checks
without a second toolchain or sed quoting hazards. The
single-source-of-truth contract (everything lives in
`clusters/_fleet.yaml`; bootstrap stages `yamldecode` it) holds
throughout. Post-init-fill fields (§16.1) render as `null` / `[]` with
`TODO` comments rather than angle-bracket `<...>` sentinels:
bootstrap preconditions use a single `!= null && != ""` check, and no
placeholder string ever leaks into provider resources.

### 16.1 Single source of truth

All adopter-specific values live in `clusters/_fleet.yaml`. That file is
**generated** by the `init/` module on first run from
`init/templates/_fleet.yaml.tftpl`; the tftpl and the entire `init/`
directory are deleted post-render.

Fields the adopter supplies (via interactive prompts; see §16.3):

- `fleet.name` — short slug, lowercase alnum, ≤ 12 chars (feeds into
  resource naming derivations; see §16.6).
- `fleet.display_name` — human-friendly name for README and Grafana.
- `fleet.tenant_id` — Entra tenant GUID.
- `fleet.github_org` — GitHub org/user owning the fleet repo.
- `fleet.github_repo` — fleet repo name (e.g. `platform-fleet`).
- `fleet.team_template_repo` — team template repo name.
- `envs.mgmt.location` — default Azure region for mgmt-only
  resources that are not bound to a cluster env-region (fleet RGs,
  fleet-meta UAMI, tenant-scope role assignments, fleet ACR).
- `envs.mgmt.subscription_id`, `.nonprod.subscription_id`,
  `.prod.subscription_id`. `acr.subscription_id` and
  `state.subscription_id` are derived from
  `envs.mgmt.subscription_id` (not separately prompted): fleet-shared
  resources (ACR, tfstate SA, fleet KV) are PE-wired into the mgmt
  VNet's `snet-pe-fleet` and must live in the mgmt subscription.
- `dns.fleet_root` — e.g. `int.acme.example`.

Fields intentionally **not** prompted (filled post-init; tagged with
angle-bracket `<...>` placeholders or `TODO` in the rendered yaml):

- AAD group object IDs (`aad.argocd.owners`, `aad.kargo.owners`,
  per-env `aks.admin_groups`, `rbac_cluster_admins`, `rbac_readers`,
  `grafana.admins`, `grafana.editors`).
- Networking resource ids —
  `networking.envs.<env>.regions.<region>.hub_network_resource_id`,
  `networking.private_dns_zones.{blob,vaultcore,azurecr,grafana}` —
  the adopter typically fills these after provisioning (or pointing
  at) the hub VNets and central private DNS zones out-of-band.
  Address spaces under `networking.envs.<env>.regions.<region>.address_space`
  (for every env including `mgmt`) are prompted (they're pure CIDR
  math, known at adoption time).

These typically aren't known at adoption time and the adopter edits
`clusters/_fleet.yaml` directly after init. Everything else (CIDRs,
K8s versions, node SKUs, autoscaler tuning) stays in
`clusters/_defaults.yaml` with fleet-wide defaults.

### 16.2 Bootstrap Terraform reads yaml (no duplication)

`terraform/bootstrap/fleet` and `terraform/bootstrap/environment` read
`clusters/_fleet.yaml` directly via `yamldecode(file(...))` locals,
matching the pattern runtime stages already use (via
`terraform/config-loader/load.sh`).

- `terraform/bootstrap/fleet/variables.tf` shrinks to:
  `fleet_stage0_fic_subject`, `fleet_meta_fic_subject`,
  `fleet_repo_visibility`, `gh_repo_module_source` (all optional).
- `terraform/bootstrap/environment/variables.tf` keeps `env`,
  `env_reviewers_count`, `location` (optional; defaults to
  `local.envs.mgmt.location` for env=mgmt or to the env-region key
  under `networking.envs.<env>.regions` for other envs),
  `fleet_meta_principal_id`.
- All resources reference `local.fleet.*` / `local.envs.<env>.*`
  / `local.derived.*`.

Name derivation (ACR, fleet KV, state SA, env KV, cluster KV,
resource groups) must agree between `load.sh` and bootstrap-stage
HCL locals. The canonical spec lives in `docs/naming.md` (see §16.6)
and is validated by a CI diff between the two implementations against
a fixture `_fleet.yaml`.

### 16.3 `init-fleet.sh` responsibilities

A thin wrapper around `init/` (the throwaway Terraform module).
Interactive wizard by default; `--non-interactive` plus optional
`--values-file <path>.tfvars` for CI.

1. **Preflight**: require `terraform` (≥ 1.9) and `git`; refuse to run
   if `.fleet-initialized` exists or the worktree is dirty (override
   with `--force`).
2. **Overlay** (if `--values-file` is passed): for each `key = "value"`
   line in the overlay file, patch the matching line in
   `init/inputs.auto.tfvars` via a small python-inline rewrite.
3. **Prompt** for any variable in `init/inputs.auto.tfvars` still set
   to the sentinel `"__PROMPT__"`. The prompt text is derived from the
   inline `# comment` after each variable line.
4. **Apply** the `init/` module via
   `terraform -chdir=init init && terraform apply -auto-approve`.
   Terraform's variable validation blocks reject malformed GUIDs,
   slugs, DNS names, etc. — the shell contains zero format regexes.
5. Terraform renders (via `local_file` + `templatefile`):
   - `clusters/_fleet.yaml`
   - `.github/CODEOWNERS` (`* @<github_org>/platform-engineers`)
   - `README.md` (replaces the pre-init template README)
   - `.fleet-initialized` marker (yamlencoded; committed)
6. **Offer to remove example clusters**
   (`clusters/mgmt/eastus/aks-mgmt-01`,
   `clusters/nonprod/eastus/aks-nonprod-01`). Default: keep.
7. **Self-cleanup**: delete `init/`, `init-fleet.sh` itself,
   `.github/workflows/template-selftest.yaml`,
   `.github/workflows/status-check.yaml`, and `.github/fixtures/` so
   the adopter repo contains zero template machinery. Also strip the
   `**/.terraform.lock.hcl` line from `.gitignore` — the template
   repo ignores lock files to avoid churn from local/CI
   `terraform init`, but adopter repos should commit them for
   reproducibility. Template history remains accessible via
   `git log`.

### 16.4 `init-gh-apps.sh` — GitHub App provisioning helper

Two GitHub Apps (`fleet-meta`, `stage0-publisher`; rationale and
permission split in §4 Stage -1 `bootstrap/fleet`) plus a third
(`fleet-runners`; repo-scoped `actions:read` + `metadata:read` used
by the self-hosted runner pool's KEDA scaler — see §4 Stage -1
`bootstrap/fleet` → *Runner infrastructure*) must exist on the
fleet repo before `bootstrap/fleet` runs. The GitHub Apps API has
**no headless creation endpoint** — every App must be born through
the App Manifest flow, which requires a one-time browser handshake to
record the operator's consent to the requested permissions. This
script automates everything around that single click.

Lives at the **repo root** next to `init-fleet.sh`, not inside
`init/`. `init-fleet.sh` deletes the entire `init/` tree on
self-cleanup (§16.3 step 7), which runs before this helper is
invoked — anything placed under `init/` would therefore already be
gone.

Run order: after `init-fleet.sh` (so `_fleet.yaml` exists) and before
`terraform -chdir=terraform/bootstrap/fleet apply`. Idempotent: if
all three apps already exist on `<fleet.github_org>` and their PEMs
are already captured in the state file (`./.gh-apps.state.json` at
repo root, gitignored), the script exits 0 with a "nothing to do"
message.

Steps, per App:

1. **Build the manifest** from `_fleet.yaml` (`fleet.github_org`,
   `fleet.github_repo`, the App-specific permission set, and a
   single-use `redirect_url` of `http://127.0.0.1:<random-port>/cb`).
2. **Open a localhost listener** on the random port, bound to
   `127.0.0.1` only, with a 5-minute timeout.
3. **Print and (when stdout is a TTY) `open(1)`** the manifest URL:
   `https://github.com/organizations/<org>/settings/apps/new?state=<nonce>`
   with the manifest as a hidden form value (operator clicks
   "Create GitHub App" once and is redirected to the listener).
4. **Capture** the `?code=<temp_code>&state=<nonce>` redirect;
   verify the nonce.
5. **Exchange** the code:
   `gh api -X POST /app-manifests/<code>/conversions` →
   `{ id, slug, client_id, client_secret, pem, webhook_secret }`.
   These values are returned **once**; the script writes them
   immediately to `./.gh-apps.state.json` (mode 0600, gitignored).
6. **Install** the App on the fleet repo:
   `gh api -X POST /orgs/<org>/installations` (operator may be
   re-prompted in the browser to confirm install scope).
7. **Emit** a tfvars overlay file (`./.gh-apps.auto.tfvars` at repo
   root, gitignored) with the variable names Stage 0 consumes:

   ```hcl
   fleet_meta_app_id             = "<id>"
   fleet_meta_app_client_id      = "<client_id>"
   fleet_meta_app_pem            = <<EOT
   <pem>
   EOT
   fleet_meta_app_webhook_secret = "<webhook_secret>"

   stage0_publisher_app_id              = "<id>"
   stage0_publisher_app_client_id       = "<client_id>"
   stage0_publisher_app_pem             = <<EOT
   <pem>
   EOT
   stage0_publisher_app_webhook_secret  = "<webhook_secret>"

   fleet_runners_app_id                 = "<id>"
   fleet_runners_app_client_id          = "<client_id>"
   fleet_runners_app_pem                = <<EOT
   <pem>
   EOT
   fleet_runners_app_webhook_secret     = "<webhook_secret>"
   ```

   **Stage 0** declares matching `variable` blocks (not
   `bootstrap/fleet`: `bootstrap/fleet` creates the empty fleet KV
   but does not write secret material into it). Stage 0's tf-apply
   workflow symlinks or copies `.gh-apps.auto.tfvars` into
   `terraform/stages/0-fleet/` so `terraform plan/apply` picks it up
   as an additional variable source. Stage 0 then writes the PEMs +
   webhook secrets into the fleet KV created by `bootstrap/fleet`
   (Stage 0 holds `Key Vault Secrets Officer` on the vault; the role
   assignment is created in `bootstrap/fleet` to the `fleet-stage0`
   UAMI), including the `fleet-runners` PEM at the secret name
   referenced by `_fleet.yaml`
   `github_app.fleet_runners.private_key_kv_secret`, which the
   runner pool's ACA job reads at scale-out via KV reference — see
   §4 Stage -1 `bootstrap/fleet` → *Runner infrastructure*), and
   publishes the App ids / client ids as fleet-repo variables (see
   §4 Stage 0 outputs) so downstream workflows can mint installation
   tokens.

Failure modes the script handles explicitly:

- `GITHUB_TOKEN` missing or wrong scopes → fail before opening the
  browser; print the required `repo:admin` + `admin:org` scopes.
- Operator closes the browser without clicking → 5-minute listener
  timeout; rerun the script (idempotent for the App that already
  succeeded).
- Manifest exchange returns 404/410 → temp_code expired; rerun.
- App already exists with the same name → list existing Apps via
  `gh api /orgs/<org>/installations` and skip creation; if the
  existing App's PEM is *not* in `./.gh-apps.state.json`, abort
  with a clear message (the operator must rotate the PEM via
  `gh api -X POST /apps/<slug>/keys` and re-run).

Self-cleanup: the script `rm`s itself after a successful run in
which all three Apps exist, are installed, and the tfvars overlay
has been written. The state file (`./.gh-apps.state.json`) and
tfvars overlay (`./.gh-apps.auto.tfvars`) remain on disk (both
gitignored)
until Stage 0 has successfully applied — their authoritative storage
post-Stage-0 is the fleet KV (PEMs/webhook secrets) and fleet-repo
variables (ids/client ids). The adopter may delete both files
manually after the first green Stage 0 apply; leaving them in place
is harmless.

### 16.5 GitHub template repo mechanics

- The template repo is marked "Template repository" in GitHub Settings
  (repo admin action, documented in `docs/adoption.md`).
- Adopter flow: *Use this template → Create new repository* → clone
  locally → run `./init-fleet.sh` → commit → push.
- No `git remote` manipulation is required; GitHub instantiation
  handles repo identity. `init-fleet.sh` does not touch git remotes.
- `github_repository` resources in `bootstrap/fleet` read repo names
  from `local.fleet.*`. The fleet repo itself already exists (the
  adopter created it via "Use this template"), so `main.github.tf`
  ships an `import { to = github_repository.fleet, id =
  local.fleet.github_repo }` block that adopts the existing repo into
  state on the first apply — **no manual `terraform import` step is
  required**. The team-template repo is created fresh by the apply.

### 16.6 Name derivation spec (`docs/naming.md`)

Canonical, implementation-neutral spec for every derived resource
name. Implemented identically in `terraform/config-loader/load.sh`
and in bootstrap-stage HCL locals. Initial rules:

- **State SA**: `st<fleet.name>tfstate` (truncate + lowercase to 24
  chars; fail-fast if `fleet.name` produces an invalid name).
- **Fleet ACR**: `acr<fleet.name>shared`.
- **Fleet KV**: `kv-<fleet.name>-fleet` (≤ 24 chars).
- **Env KV** (future): `kv-<fleet.name>-<env>`.
- **Cluster KV**: `kv-<cluster.name>` (≤ 24 chars; truncation rule
  documented).
- **State containers**: `tfstate-fleet`, `tfstate-<env>`,
  `tfstate-cluster-<cluster.name>`.
- **Resource groups**: `rg-fleet-tfstate`, `rg-fleet-shared`,
  `rg-fleet-<env>-shared`, `rg-dns-<env>`, `rg-obs-<env>`,
  `rg-<cluster.name>`.
- **UAMIs**: `uami-fleet-stage0`, `uami-fleet-meta`,
  `uami-fleet-<env>`, `uami-kargo-mgmt`, `uami-<cluster.name>-cp`,
  `uami-<cluster.name>-kubelet`, `uami-<cluster.name>-workload-<svc>`.
- **DNS zones**: `<cluster.name>.<cluster.region>.<cluster.env>.<dns.fleet_root>`
  (per-cluster private zone under the fleet root).

Overrides (`acr.name_override`, `keyvault.name_override`,
`state.storage_account_name_override`) bypass derivation when set.

### 16.7 Safety rails

- Pre-init README banner block (bounded by `<!-- fleet:banner -->`
  sentinels) warns that `./init-fleet.sh` is the adopter entry point.
  The TF module's README template omits the banner, so a successful
  init removes it.
- `init-fleet.sh` refuses to run on a dirty worktree or a repo with an
  existing `.fleet-initialized` marker unless `--force` is passed.
- Terraform's variable validation blocks reject malformed inputs before
  any file is written (no partial renders).
- The `__PROMPT__` sentinel is a build-time guard: Terraform fails
  validation on it (it's not a valid GUID / slug / DNS name), so even
  a buggy wrapper can't apply with a sentinel unsubstituted.

### 16.8 Template-repo self-test

`.github/workflows/template-selftest.yaml` runs on the **template repo
itself** (deleted by `init-fleet.sh` in adopter repos). Steps:

1. Run `init-fleet.sh --non-interactive --force --values-file
   .github/fixtures/adopter-test.tfvars` on the CI checkout.
2. Assert the init machinery (`init/`, `init-fleet.sh`, selftest
   workflow, fixtures dir) was removed, and the rendered artefacts
   (`clusters/_fleet.yaml`, `.fleet-initialized`) exist and parse.
3. `terraform fmt -check` + `terraform validate` on `bootstrap/fleet`
   and `bootstrap/environment` against the rendered `_fleet.yaml`.
4. Run `config-loader/load.sh` for each example cluster; assert it
   produces valid JSON.

Does not run `terraform plan` against Azure/GitHub (no creds); keeps
the template verified purely offline.

### 16.9 Files added / modified for templating

**New**

- `init-fleet.sh` — wrapper: preflight, prompts, `terraform apply`, cleanup.
- `init/main.tf`, `init/variables.tf`, `init/render.tf`, `init/outputs.tf`
  — throwaway Terraform root module.
- `init/inputs.auto.tfvars` — adopter input file with `"__PROMPT__"`
  sentinels.
- `init/templates/_fleet.yaml.tftpl` — rendered to
  `clusters/_fleet.yaml`.
- `init/templates/CODEOWNERS.tftpl` — rendered to `.github/CODEOWNERS`.
- `init/templates/README.md.tftpl` — rendered to `README.md`
  (replaces the pre-init banner'd README).
- `docs/adoption.md` — adopter-facing guide.
- `docs/naming.md` — canonical name-derivation spec.
- `.github/fixtures/adopter-test.tfvars` — selftest values.
- `.github/workflows/template-selftest.yaml`.
- `.fleet-initialized` — written by init, committed in adopter repo.

**Modified**

- `terraform/bootstrap/fleet/{variables,main,main.state,main.identities,main.github,providers,outputs}.tf`
  — reduced `variables.tf`; all resources reference `local.fleet.*`
  / `local.derived.*` via `yamldecode(file("../../../clusters/_fleet.yaml"))`.
- `terraform/bootstrap/environment/{variables,main,main.state,main.identities,main.observability,main.github,providers}.tf`
  — same pattern; `var.location` optional, defaults to
  `local.envs.mgmt.location` (env=mgmt) or the env-region key under
  `networking.envs.<env>.regions`.
- `terraform/config-loader/load.sh` — injects
  `cluster.subscription_id` from
  `_fleet.yaml.envs.<env>.subscription_id` if not already set.
- `README.md` — branding/banner sentinel blocks; "Adopting this
  template" section.
- `.gitignore` — adds `.fleet-bootstrap/`; keeps `.fleet-initialized`
  un-ignored.

**Unchanged**

- `clusters/_defaults.yaml` and env `_defaults.yaml` (non-identity
  tuning only; subscription IDs sourced from
  `_fleet.yaml.envs.<env>.subscription_id` and stitched in
  by the config-loader).
- Runtime stages (`0-fleet`, `1-cluster`, `2-platform`), which
  already read yaml.

### 16.10 Execution order (completed in Phase 1)

1. [x] Draft `docs/naming.md` (locks the derivation contract).
2. [x] Refactor `bootstrap/fleet` + `bootstrap/environment` to read
   `_fleet.yaml` via locals.
3. [x] Build `init/` throwaway Terraform module (replaces the initial
   sed-based `_fleet.yaml.template` approach).
4. [x] Write `init-fleet.sh` wrapper (interactive + non-interactive
   modes via tfvars overlay).
5. [x] Add README sentinel blocks and pre-init banner; template a
   new post-init README.md.tftpl.
6. [x] Write `docs/adoption.md`.
7. [x] Add template-selftest workflow + tfvars fixture.
8. [x] Dedup subscription IDs out of env `_defaults.yaml`; stitch from
   `envs.<env>.subscription_id` via `config-loader/load.sh`.
9. [x] Smoke test: non-interactive init in a throwaway clone; confirm
   rendered `_fleet.yaml` parses and template scaffolding is removed.
10. [ ] Follow-up (deferred to Phase 2 CI work): CI diff between
    `load.sh` name derivation and bootstrap-stage HCL locals against a
    fixture `_fleet.yaml`.
