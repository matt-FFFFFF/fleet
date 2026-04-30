# Adopting the fleet template

This repository ships as a **GitHub template**. Adopters produce their
own fleet repo in three steps.

## 1. Instantiate

On GitHub, click **Use this template → Create new repository**. Give it
a name (e.g. `platform-fleet`) under your org.

Optionally mark **Include all branches** unchecked (default).

## 2. Clone and initialize

```sh
git clone git@github.com:<your-org>/<your-fleet-repo>.git
cd <your-fleet-repo>
./init-fleet.sh
```

Under the hood `init-fleet.sh` is a thin wrapper around a throwaway
Terraform root module in `init/`:

1. The wrapper reads `init/inputs.auto.tfvars` and, for every variable
   still set to the sentinel `"__PROMPT__"`, prompts on the TTY and
   writes the answer back into the file.
2. It then runs `terraform -chdir=init init && terraform apply`.
   Terraform validates each input against a regex (GUIDs, slugs, DNS
   names) and renders the following via `templatefile()`:
   - `clusters/_fleet.yaml`
   - `.github/CODEOWNERS`
   - `README.md` (replaces the pre-init template README)
   - `.fleet-initialized`
3. The wrapper optionally removes the example clusters
   (`aks-mgmt-01`, `aks-nonprod-01`), then deletes `init/`, itself, the
   selftest workflow, and the CI fixtures directory. The adopter repo
   ends up with zero template machinery.

Prompted fields:

| Variable                                      | Description                                                                               |
| --------------------------------------------- | ----------------------------------------------------------------------------------------- |
| `fleet_name`                                  | Short slug, ≤12 chars, used in resource naming.                                           |
| `fleet_display_name`                          | Human-friendly name for README + Grafana.                                                 |
| `tenant_id`                                   | Entra tenant GUID.                                                                        |
| `github_org`                                  | GitHub org/user owning the fleet repo.                                                    |
| `github_repo`                                 | Fleet repo name (default `platform-fleet`).                                               |
| `team_template_repo`                          | Team template repo name (default `team-repo-template`).                                   |
| `primary_region`                              | Default Azure region (default `eastus`). Used as the single region for the initial per-env VNets; adopters add more regions by editing `clusters/_fleet.yaml` post-init. |
| `dns_fleet_root`                              | Parent private DNS zone (e.g. `int.acme.example`).                                        |
| `networking_pdz_blob`                         | BYO `privatelink.blob.core.windows.net` private DNS zone id.                              |
| `networking_pdz_vaultcore`                    | BYO `privatelink.vaultcore.azure.net` private DNS zone id.                                |
| `networking_pdz_azurecr`                      | BYO `privatelink.azurecr.io` private DNS zone id.                                         |
| `networking_pdz_grafana`                      | BYO `privatelink.grafana.azure.com` private DNS zone id.                                  |
| `environments` (map)                          | Per-env identity + networking inputs. Map key is the env name (`mgmt`, `nonprod`, `prod`, … — `mgmt` is required). Each entry carries: `subscription_id` (GUID), `address_space` (CIDR, min `/20`, RFC1918, strictly aligned, pairwise disjoint across envs), and optional `hub_network_resource_id` (full ARM VNet id; null ⇒ that env-region opts out of hub peering). Rendered into `envs.<env>.subscription_id` and `networking.envs.<env>.regions.<primary_region>.{address_space, hub_network_resource_id}`. Fleet-shared resources (ACR, tfstate SA, fleet KV) land in the **`mgmt`** subscription — no separate `sub_shared` prompt. |

The `environments` map is entered interactively one env at a time
(each prompt asks for that env's three fields in sequence). Adopters
who want env names beyond the default `{mgmt, nonprod, prod}` —
`dev`, `stage`, `qa`, `preprod`, etc. — edit
`init/inputs.auto.tfvars` before running `init-fleet.sh` to add map
entries.

Pod IPs use a shared fleet-wide `/16` in CGNAT (`100.64.0.0/16`) hard-
coded in `modules/aks-cluster`, so there is no per-region pod-CIDR slot
to pick; see `docs/networking.md` § "Pod CIDR (shared)" for rationale.

Pairwise-distinct and CIDR-syntax validators run at `terraform apply`
time inside `init/`; malformed inputs are rejected before anything
lands in `_fleet.yaml`. See `docs/networking.md` for the two-pool
subnet layout carved out of each address space (and, on mgmt
env-regions, the additional fleet-plane zone in the upper `/(N+1)`).

Non-interactive alternative (for CI / testing):

```sh
# Option A: pre-fill init/inputs.auto.tfvars in the checkout, then:
./init-fleet.sh --non-interactive

# Option B: overlay values from an external tfvars file:
./init-fleet.sh --non-interactive --values-file path/to/adopter.tfvars
```

The overlay file uses plain HCL `key = "value"` lines (see
`.github/fixtures/adopter-test.tfvars` for a minimal example).

## 3. Post-init edits

Some values can't be prompted because they typically don't exist yet
at adoption time. Fill these into `clusters/_fleet.yaml` before the
first Terraform apply — the file documents each with a `TODO` or
`<placeholder>`:

- `aad.argocd.owners`, `aad.kargo.owners` — AAD object IDs of app owners.
- Per-env `aks.admin_groups`, `rbac_cluster_admins`, `rbac_readers`.
- Per-env `grafana.admins`, `grafana.editors`.
- `github_app.fleet_runners.{app_id, installation_id}` — numeric IDs
  of the `fleet-runners` GitHub App (KEDA polling; created by §4
  below). The private key PEM is seeded into the fleet Key Vault by
  `init-gh-apps.sh` under the secret name `private_key_kv_secret`
  (default `fleet-runners-app-pem`). Because the KV is strictly
  private, `init-gh-apps.sh` must run from a host with data-plane
  reach to the vault (jump host, VPN, Bastion, or the fleet runners
  themselves once online).

Networking (everything under `networking.*` and the per-env
`envs.<env>.subscription_id` in `_fleet.yaml`) was prompted in §2
and is already fully populated — the four central private DNS zones
(blob / vaultcore / azurecr / grafana), every env's subscription id,
and every env's per-region `address_space` + optional
`hub_network_resource_id`. Pod IPs use a shared fleet-wide `/16`
(`100.64.0.0/16`) hard-coded in `modules/aks-cluster`, so there is no
per-region pod-CIDR slot to set. There is **no** per-service BYO
subnet id to fill in: `bootstrap/fleet` carves the mgmt-only
fleet-plane subnets (`snet-pe-fleet`, `snet-runners`), and
`bootstrap/environment` carves the env-plane subnets (`snet-pe-env`,
api pool, nodes pool) on every env-region — mgmt included — from
those address spaces. See `docs/networking.md` for the two-pool
layout and `docs/onboarding-cluster.md` for the single-PR new-cluster
flow (picking `subnet_slot`).

### Handling globally-unique-name collisions

Three resources this repo creates have **Azure-globally-unique** names
— the chosen `fleet.name` slug is woven into them and must be unique
across every Azure tenant worldwide:

| Resource       | Default formula             | Length cap | Override field                       |
| -------------- | --------------------------- | ---------- | ------------------------------------ |
| Fleet state SA | `st<fleet.name>tfstate`     | 24         | `state.storage_account_name_override` |
| Fleet ACR      | `acr<fleet.name>shared`     | 50         | `acr.name_override`                   |
| Runners KV     | `kv-<fleet.name>-runners`   | 24         | `runners_keyvault.name_override`      |

If you hit `StorageAccountAlreadyTaken` / `RegistryNameAlreadyExists`
/ `VaultAlreadyExists` on the first `terraform apply` (or after a
tear-down before the soft-deleted Key Vault has purged — KV
soft-delete retention is 7-90 days, default 90), edit
`clusters/_fleet.yaml` and set the relevant `*_override` field to a
globally-unique name you've verified is free, then re-run apply.
Overrides bypass the formula completely; you are responsible for
length and character-class compliance (see `docs/naming.md` §
"Override semantics").

The same pattern applies to per-cluster Key Vaults (`kv-<cluster.name>`,
24-char cap, globally unique): set `platform.keyvault.name` in the
relevant `cluster.yaml` to override.

Commit the initialized repo:

```sh
git add -A
git commit -m "chore: initialize fleet from template"
git push
```

## 4. Provision the GitHub Apps

The fleet uses two GitHub Apps with deliberately different blast
radius (rationale in `PLAN.md` §4 Stage -1):

- **`fleet-meta`** (admin-class) — used by env-bootstrap and
  team-bootstrap workflows behind a 2-reviewer gate. Also publishes
  fleet-scope repo variables from `bootstrap/{fleet,environment}` and
  Stage 1 mgmt apply post-steps.
  Permissions: `administration:write`, `environments:write`,
  `variables:write`, `secrets:write`, `contents:write`.
- **`fleet-runners`** (narrow) — used by the KEDA scaler inside the
  fleet runner pool to poll for queued runner jobs on this repo.
  Permissions: `actions:read`, `metadata:read`. Installed on the
  fleet repo only. Private key PEM is seeded into the fleet Key Vault
  by `init-gh-apps.sh` (post-bootstrap step); `bootstrap/fleet` owns
  the KV itself and references the secret via a versionless KV URI
  resolved at runtime by the Container App Job's managed identity
  (see `networking` / `github_app.fleet_runners` in `_fleet.yaml`).

Neither App can be created headlessly: the GitHub Apps API requires
a one-time browser handshake (the App Manifest flow) so a human can
consent to the requested permissions. The `init-gh-apps.sh` helper
(see `PLAN.md` §16.4) — placed at the **repo root** alongside
`init-fleet.sh`, because `init-fleet.sh` deletes the entire `init/`
tree on self-cleanup — automates everything around that single
click: building the manifest from `_fleet.yaml`, opening a localhost
listener for the redirect, exchanging the temp code for the App
credentials, and guiding the installation flow for both Apps
(the operator chooses the repo selection in the GitHub install UI;
the script records the owner-scoped installation id but does not
verify repo-selection coverage).

> **Status:** `init-gh-apps.sh` is implemented at the repo root
> (PLAN §16.4). The command block below is the actual adopter
> experience. The Terraform-side consumer of App material is
> `bootstrap/fleet` (the `fleet-runners` PEM); workflow-side consumers
> (`fleet-meta`-driven env/team bootstrap) read App credentials at
> runtime via the GitHub App installation.

### Running `init-gh-apps.sh`

Authenticate `gh` first — the script uses `gh api` throughout and
accepts any of its credential sources:

```sh
# Either: use the gh keyring
gh auth login --scopes 'repo,admin:org'

# Or: export a PAT (GH_TOKEN and GITHUB_TOKEN both work)
export GH_TOKEN=<PAT with repo + admin:org>

./init-gh-apps.sh
```

The script persists the full App payload (App IDs, `client_id`,
`client_secret`, PEMs, webhook secrets, and other App metadata for both
Apps) to `./.gh-apps.state.json` (gitignored, mode 0600) and
writes a narrow per-module overlay at
`terraform/bootstrap/fleet/.gh-apps.auto.tfvars` (gitignored, mode
0600) carrying only `fleet_runners_app_pem` +
`fleet_runners_app_pem_version`. `bootstrap/fleet` (Stage -1) owns the
fleet Key Vault and seeds the `fleet-runners` PEM into it during its
apply, consuming the `fleet_runners_app_pem` variable declared in
`terraform/bootstrap/fleet/variables.tf` (ephemeral + sensitive; never
lands in state) and writing the secret via the Key Vault data-plane
API. Because the overlay lives at the module root, `terraform apply`
auto-loads it without an explicit `-var-file` flag. The executor
running the apply must have private-network reach to the KV
(`<vault>.vault.azure.net`).
The full App payload — additional PEMs, client secrets, and webhook
secrets — stays in `./.gh-apps.state.json`; no other tfvars file is
emitted. Workflow-level consumers (`fleet-meta`-driven env-bootstrap
and team-bootstrap) read App credentials at runtime via the App
installation, not from tfvars. Both files (`.gh-apps.state.json` and
the `bootstrap/fleet` overlay) remain on disk after applies. Keep
them as long as you may need to re-plan or re-apply
`terraform/bootstrap/fleet`: the `fleet_runners_app_pem`
variable is `ephemeral` + `sensitive` + `nullable = false`, and
`bootstrap/fleet` writes the PEM into Key Vault via a write-only
data-plane `sensitive_body` — Terraform cannot read it back from
state or from KV, so every future plan/apply needs the PEM supplied
again. If you do delete the overlay, you must supply the PEM on each
subsequent apply via another source (for example
`export TF_VAR_fleet_runners_app_pem="$(jq -r '."fleet-runners".pem' .gh-apps.state.json)"`
from a kept copy of the state file, or from a password manager / secret
store you have safely stashed it in). The equivalent applies to a PEM
rotation: bump `fleet_runners_app_pem_version` (the overlay does this
automatically on re-run of `./init-gh-apps.sh`; otherwise bump it by
hand) to drive a re-PUT of the KV secret.

## 5. Bootstrap Terraform

### 5.1 Prerequisites

Before invoking `terraform apply` on `bootstrap/fleet`, all of the
following must be true. The adoption helpers (§2 above and §4
above) handle the repo-state items automatically; the Azure and
GitHub items must be arranged out-of-band by the adopter org.

**Azure**

- `az login` session in the tenant identified by
  `_fleet.yaml.fleet.tenant_id`. Both providers run with
  `use_cli = true`; no service-principal env vars are read.
- Tenant role: **Global Administrator** or **Cloud Application
  Administrator** — required to create the Argo / Kargo AAD
  application registrations + service principals via the `azuread`
  provider in `bootstrap/fleet`. No standing Microsoft Graph grant
  is issued on any UAMI; AAD-app lifecycle is operator-owned and
  re-runs of `bootstrap/fleet` (for re-rolls or KV writes) require
  the same role.
- Subscription role on `_fleet.yaml.acr.subscription_id`:
  **Owner** (or Contributor + User Access Administrator).
- Resource provider registrations on the shared subscription:
  `Microsoft.Storage`, `Microsoft.Resources`,
  `Microsoft.ManagedIdentity`, `Microsoft.Authorization`,
  `Microsoft.ContainerRegistry`. Not enforced in code; an
  RP-not-registered error is the most common first-apply failure.
- Names that must be free (or matched by overrides in
  `_fleet.yaml`): storage account `st<fleet.name>tfstate` (≤24
  chars, globally unique), resource groups `rg-fleet-tfstate` and
  `rg-fleet-shared`.

**Networking (Stage -1 runner pool + private tfstate SA)**

- Hub VNet (adopter-owned) — one reference per env-region via
  `networking.envs.<env>.regions.<region>.hub_network_resource_id`.
  Each entry is nullable: null opts that env-region out of hub
  peering (adopter-managed routing). When set, `bootstrap/fleet`
  peers the mgmt VNet for that region to the hub, and
  `bootstrap/environment` peers each non-mgmt env VNet for that
  region. Neither stage creates the hub itself.
  `bootstrap/fleet` authors the mgmt VNet shell
  (`vnet-<fleet>-mgmt-<region>` in `rg-net-mgmt-<region>`) from
  `networking.envs.mgmt.regions.<region>.address_space` and carves
  `snet-pe-fleet` (`/26`) + `snet-runners` (`/23`) out of the upper
  `/(N+1)` of that address space. The runner subnet is delegated to
  `Microsoft.App/environments` and egresses via the hub firewall
  when `egress_next_hop_ip` is set on that region. UDR ownership on
  the fleet plane is in-repo as the mgmt-only route table
  `rt-fleet-<region>`, associated with both `snet-pe-fleet` and
  `snet-runners`, unless an adopter overrides on a per-subnet basis
  via `subnet_route_table_ids` (see next bullet). Cluster-workload
  UDR lives on `rt-aks-<env>-<region>` (a separate RT) per-env-region.
  See `docs/networking.md` § "Route table / UDR egress".
- **Hub-and-spoke knobs (all optional; pre-F6 defaults preserved
  when omitted).** Per
  `networking.envs.<env>.regions.<region>` entry:
    * `egress_next_hop_ip` (string | null, default null). Already
      drives `rt-aks-<env>-<region>`; also drives `rt-fleet-<region>`
      on mgmt env-regions (association: `snet-pe-fleet` +
      `snet-runners`). Null = no repo-owned route table on the
      fleet plane (island-VNet default).
    * `hub_peering.use_remote_gateways` (bool, default false).
      Configured at
      `networking.envs.<env>.regions.<region>.hub_peering.use_remote_gateways`
      (nested under `hub_peering:` so future sibling knobs can live
      alongside it). Set `true` only when the hub has a VPN or
      ExpressRoute gateway the spoke needs to learn routes from;
      Azure rejects the peering otherwise.
    * `dns_servers` (list(string), default `[]`). `[]` = Azure-
      provided DNS (168.63.129.16). Populate with the central
      Private DNS Resolver inbound-endpoint IPs when split-horizon
      or on-prem DNS forwarding is required.
    * `subnet_route_table_ids` (map(string), default `{}`). Per-
      subnet RT-id override. Keys: `pe-fleet`, `runners` (mgmt
      only), and `pe-env` (every env). Values: full ARM
      `Microsoft.Network/routeTables/<name>` resource ids of a
      hub-owned RT. When set for a subnet, it wins over any
      module-created RT derived from `egress_next_hop_ip`.
      Intended for adopters whose hub team forbids spoke-owned RTs
      on the peered subnets.
- Central `privatelink.blob.core.windows.net` private DNS zone
  (typically in the hub connectivity subscription; shared with every
  other storage account in the tenant). Referenced by id in
  `_fleet.yaml.networking.private_dns_zones.blob`; `bootstrap/fleet`
  registers the tfstate SA's PE A-record there.
- Central `privatelink.vaultcore.azure.net` private DNS zone. Same
  ownership model; referenced as `networking.private_dns_zones.vaultcore`;
  carries the fleet KV's PE A-record.
- Central `privatelink.azurecr.io` private DNS zone. Same ownership
  model; referenced as `networking.private_dns_zones.azurecr`;
  carries the fleet ACR and per-pool runner ACR PE A-records.
- Central `privatelink.grafana.azure.com` private DNS zone.
  Referenced as `networking.private_dns_zones.grafana`;
  `bootstrap/environment` registers each env's Grafana PE A-record.
- Role assignment: **`Private DNS Zone Contributor`** on all four
  central zones — for the operator on the first apply, **and** for
  the `fleet-meta` and `fleet-<env>` UAMIs for every subsequent re-run.
- **VNet-reachable workstation for every apply**: jump host,
  Azure Bastion, or VPN into the fleet VNet. The tfstate SA is
  private-only from the very first apply — Terraform cannot reach
  it from a laptop over the public internet.

**GitHub**

- Fleet repo already exists (created via "Use this template" in
  §1); `bootstrap/fleet` adopts it via an `import` block.
- `GITHUB_TOKEN` exported with classic-PAT scopes `repo:admin`
  and `admin:org` (the latter only if `github_org` is an
  organization).
- The `fleet-meta` GitHub App from §4 is **not** required for the
  initial `bootstrap/fleet` apply — it becomes relevant for later
  workflows (env-bootstrap, team-bootstrap, and fleet-scope repo-var
  publishing post-apply). Its credentials persist in
  `./.gh-apps.state.json`. `bootstrap/fleet` does not create, write,
  or manage the GitHub App credentials.
- The **`fleet-runners`** GitHub App **is** required up-front: the
  vendored runner module validates that
  `github_app.fleet_runners.{app_id, installation_id}` are non-empty
  when `authentication_method = "github_app"`, so
  `clusters/_fleet.yaml` must carry both numeric IDs before the
  first `bootstrap/fleet` apply. The PEM itself is resolved at
  runtime by the runner Container App via a Key Vault reference;
  `bootstrap/fleet` seeds that KV secret from the
  `fleet_runners_app_pem` tfvar (see the next bullet). If the tfvars
  file is not present at first apply, `bootstrap/fleet` fails at plan
  time — the variable is `nullable = false`.
- **`fleet-runners` PEM tfvars (auto-loaded; no flag needed).**
  `init-gh-apps.sh` writes a narrow per-module overlay at
  `terraform/bootstrap/fleet/.gh-apps.auto.tfvars` containing only
  `fleet_runners_app_pem` (declared
  `sensitive`/`ephemeral`/`nullable = false` in
  `terraform/bootstrap/fleet/variables.tf`) and
  `fleet_runners_app_pem_version` (default `"0"`; bump to drive a
  re-PUT of the KV secret on rotation). Because the file lives at
  the module root, `terraform apply` auto-loads it — no `-var-file`
  flag and no "undeclared variable" warnings. `bootstrap/fleet`
  writes the PEM into the fleet KV as the `fleet-runners-app-pem`
  secret via the KV data plane. The full GitHub App payload (every
  App's IDs / client IDs / PEMs / webhook secrets) persists in
  `./.gh-apps.state.json`; no other tfvars file is derived from it.
- The team-template repo (`<github_org>/<team_template_repo>`,
  default `team-repo-template`) must **not** pre-exist; it is
  created fresh with `prevent_destroy = true`.

**Local tooling**

- `terraform` ≥ 1.9, `az` CLI, `gh` CLI (authenticated to the
  same account that holds `GITHUB_TOKEN`), `git`, `python3`,
  `bash`.

### 5.2 Apply

```sh
cd terraform/bootstrap/fleet
terraform init

# `terraform/bootstrap/fleet/.gh-apps.auto.tfvars` (written by
# `init-gh-apps.sh`, gitignored, mode 0600) carries
# `fleet_runners_app_pem` + `fleet_runners_app_pem_version` and is
# auto-loaded — no `-var-file` flag required. See §5.1.

# Apply (run from a VNet-reachable workstation; the tfstate SA is
# private-only from the first apply onward).
terraform apply
```

The fleet repo you created via "Use this template" already exists on
GitHub; `bootstrap/fleet` contains an `import` block for
`github_repository.fleet` that adopts it into state on the first apply.
No manual `terraform import` step is required.

See `PLAN.md` §4 Stage -1 for the full bootstrap sequence.

### 5.3 Two-pass `bootstrap/fleet` apply (Argo + Kargo OIDC RP secrets)

`bootstrap/fleet` owns the Argo + Kargo AAD applications + service
principals + their long-lived (2-year) RP `client_secret` values
(used by Argo CD / Dex / Kargo for human OIDC SSO login). The
secrets must land in the **mgmt cluster Key Vault**, which does
not exist until Stage 1 mgmt has run. The resolution is a
two-pass apply pattern:

1. **First pass — `bootstrap/fleet apply`**:
   - Argo + Kargo AAD apps + SPs + 2-year passwords created.
   - `ARGO_AAD_APP_ID`, `KARGO_AAD_APP_ID`, and
     `KARGO_AAD_APPLICATION_OBJECT_ID` published as repo-level
     GitHub Actions variables.
   - Runners KV created with PE + DNS zone group; operator self-
     grants `Key Vault Secrets Officer` on it (in-plan) so the
     same apply can seed `fleet-runners-app-pem` and
     `fleet-meta-app-pem` via data-plane PUT. Both PEM secrets
     come from `TF_VAR_fleet_runners_app_pem` /
     `TF_VAR_fleet_meta_app_pem`, populated by `init-gh-apps.sh`
     (§4).
   - Mgmt cluster KV writes are skipped because
     `var.mgmt_cluster_kv_id` is null (default).

2. Run `init-gh-apps.sh --keep` if needed to seed the GH App PEMs
   into the runners KV (skipped if already done).

3. **`env-bootstrap.yaml env=mgmt apply`** — creates the fleet ACR
   and publishes `ACR_*` repo vars.

4. **`tf-apply.yaml cluster=<mgmt>`** — Stage 1 mgmt creates the
   mgmt cluster and the mgmt cluster KV; publishes
   `MGMT_CLUSTER_KV_ID`, `KARGO_MGMT_UAMI_*`, and `MGMT_AKS_*`
   repo vars.

5. **Second pass — `bootstrap/fleet apply`** with
   `TF_VAR_mgmt_cluster_kv_id=<value of MGMT_CLUSTER_KV_ID>`:
   - Operator self-grants `Key Vault Secrets Officer` on the
     mgmt cluster KV (in-plan).
   - Argo + Kargo OIDC RP `client_secret` values written to the
     mgmt cluster KV via data-plane PUT.
   - ESO on every cluster (mgmt + spokes) reads them from this KV
     into the `argocd` / `kargo` namespaces.

After step 5 the apply graph is idempotent. Subsequent re-runs of
`bootstrap/fleet` (e.g. to re-roll a secret by bumping
`var.argocd_rp_secret_version` or `var.kargo_rp_secret_version`)
require only that `var.mgmt_cluster_kv_id` remains set.

The previous design (Stage 1 mgmt owning the AAD apps + a manual
Microsoft Graph `Application.ReadWrite.OwnedBy` grant on
`uami-fleet-mgmt`) has been retired. No standing Graph grant is
issued on any UAMI; AAD-app lifecycle is operator-owned. Re-runs
of `bootstrap/fleet` require the operator to hold
**Cloud Application Administrator** or **Global Administrator**
in the tenant — the same role used at first apply.

### 5.4 CI runner placement

Workflows split runner placement by what each job touches.

**Self-hosted (fleet runner pool, label `self-hosted`)** — every
job that reads or writes a private Azure data plane:

- `tf-plan.yaml` — the `cluster` matrix (reads private tfstate).
- `tf-apply.yaml` — the `cluster` matrix (writes private tfstate).
- `env-bootstrap.yaml` — the `bootstrap` job (reads runners KV +
  writes env tfstate).
- `team-bootstrap.yaml` — the `bootstrap` matrix (reads runners KV +
  writes env tfstate).

The pool is created by `bootstrap/fleet` (the KEDA-scaled Container
App Job under `rg-fleet-runners`) and is the only ingress path to
those private endpoints from a GitHub-hosted control plane. The
fleet tfstate SA, the runner-pool KV, and the mgmt cluster KV are
PE-bound with `publicNetworkAccess = Disabled`, so any
tfstate-touching or KV-touching job must run on a runner inside
the fleet VNet regardless.

**Hosted (`ubuntu-24.04`)** — every job that does not touch a
private Azure data plane:

- All of `validate.yaml` (terraform fmt, tflint, yamllint,
  subnet-slots, naming-parity).
- The initialisation-guard / `detect` / `discover` / `summarize`
  jobs in `tf-plan.yaml`, `tf-apply.yaml`, `env-bootstrap.yaml`,
  and `team-bootstrap.yaml`.
- The two template-only workflows `template-selftest.yaml` and
  `status-check.yaml`. (These run in the fleet template repo and
  on fresh forks before `init-fleet.sh`; the script deletes them
  during self-cleanup, so they never appear in adopter-repo CI.)

Why hosted for these: the trust-boundary argument that motivates
self-hosted (one image to harden, one egress path, one identity
surface) only applies to jobs that actually use that egress path.
Lint, formatting, marker-file checks, `git diff` matrix builders,
and PR-comment formatters do not. Putting them on the pool would
couple basic CI signal to a piece of infrastructure that is offline
during pool recovery — exactly when being able to lint a fix is
most valuable.

Consequence: a broken runner pool still takes Azure-touching CI
with it (`tf-plan` cluster matrix, `tf-apply` cluster matrix, both
bootstrap workflows). This is acceptable because the runner pool
is bootstrap-laptop-applied (see §5.2). Recovery is `terraform apply`
from the operator laptop against `terraform/bootstrap/fleet`, not
"another CI workflow that needs the pool to be healthy." Lint and
fmt remain green through the recovery, so the fix PR can still be
reviewed.

## Re-running `init-fleet.sh`

The script self-deletes after a successful run, so there is no
re-run path in the adopter repo. To change fleet-identity values
post-init, edit `clusters/_fleet.yaml` directly and re-apply the
bootstrap stages.
