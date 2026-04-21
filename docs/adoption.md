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
| `primary_region`                              | Default Azure region (default `eastus`).                                                  |
| `sub_shared`                                  | Subscription GUID for shared (ACR, state, fleet KV).                                      |
| `sub_mgmt`                                    | Subscription GUID for mgmt env.                                                           |
| `sub_nonprod`                                 | Subscription GUID for nonprod env.                                                        |
| `sub_prod`                                    | Subscription GUID for prod env.                                                           |
| `dns_fleet_root`                              | Parent private DNS zone (e.g. `int.acme.example`).                                        |
| `networking_hub_resource_id`                  | ARM id of the BYO hub VNet (peering target; never created by this repo).                  |
| `networking_pdz_blob`                         | BYO `privatelink.blob.core.windows.net` private DNS zone id.                              |
| `networking_pdz_vaultcore`                    | BYO `privatelink.vaultcore.azure.net` private DNS zone id.                                |
| `networking_pdz_azurecr`                      | BYO `privatelink.azurecr.io` private DNS zone id.                                         |
| `networking_pdz_grafana`                      | BYO `privatelink.grafana.azure.com` private DNS zone id.                                  |
| `networking_mgmt_address_space`               | Mgmt VNet CIDR, min `/20`, RFC1918. Carved by `bootstrap/fleet`.                          |
| `networking_env_<env>_<region>_address_space` | One per env-region (mgmt, nonprod, prod in primary_region). Min `/20`, RFC1918, disjoint. |
| `networking_env_<env>_<region>_pod_cidr_slot` | Integer `0..15`, **unique fleet-wide**. Keys each env-region's `/12` in CGNAT `100.64.0.0/10`. |

Pairwise-distinct and CIDR-syntax validators run at `terraform apply`
time inside `init/`; malformed inputs are rejected before anything
lands in `_fleet.yaml`. See `docs/networking.md` for the two-pool
subnet layout carved out of each address space.

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

Networking (everything under `networking.*` in `_fleet.yaml`) was
prompted in §2 and is already fully populated — the hub VNet id, the
four central private DNS zones (blob / vaultcore / azurecr / grafana),
and the four repo-owned VNet address spaces + per-env-region
`pod_cidr_slot`. There is **no** per-service BYO subnet id to fill in:
`bootstrap/fleet` and `bootstrap/environment` carve every PE / runner /
AKS subnet themselves from those address spaces. See
`docs/networking.md` for the two-pool layout and `docs/onboarding-cluster.md`
for the single-PR new-cluster flow (picking `subnet_slot`).

Commit the initialized repo:

```sh
git add -A
git commit -m "chore: initialize fleet from template"
git push
```

## 4. Provision the GitHub Apps

The fleet uses three GitHub Apps with deliberately different blast
radius (rationale in `PLAN.md` §4 Stage -1):

- **`fleet-meta`** (admin-class) — used by env-bootstrap and
  team-bootstrap workflows behind a 2-reviewer gate.
  Permissions: `administration:write`, `environments:write`,
  `variables:write`, `secrets:write`, `contents:write`.
- **`stage0-publisher`** (narrow) — used by the Stage 0 workflow
  to publish outputs as repo variables.
  Permissions: `variables:write` only.
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
credentials, and guiding the installation flow for all three Apps
(the operator chooses the repo selection in the GitHub install UI;
the script records the owner-scoped installation id but does not
verify repo-selection coverage).

> **Status:** `init-gh-apps.sh` is implemented at the repo root
> (PLAN §16.4). The command block below is the actual adopter
> experience. Stage 0 wiring that consumes `./.gh-apps.auto.tfvars`
> is still pending.

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

The script writes the resulting App IDs / PEMs / webhook secrets to
`./.gh-apps.auto.tfvars` (gitignored) at the repo root. `bootstrap/
fleet` (Stage -1) owns the fleet Key Vault, and the `fleet-runners`
PEM is seeded into it by this script via `az keyvault secret set`
after bootstrap completes (script host must have private-network
reach to the KV). Stage 0 seeds the remaining PEMs + webhook secrets
and publishes the App IDs / client IDs as repo variables.
`bootstrap/fleet` itself does **not** touch GH App credentials
directly — its only GH-App involvement is provisioning the vault the
PEM lands in and the `fleet-stage0` / `fleet-meta` GitHub environments
that Stage 0 later populates. The on-disk `.gh-apps.auto.tfvars` and
`.gh-apps.state.json` remain on disk (both gitignored) after Stage 0
applies; the adopter may delete them manually once the fleet KV
holds authoritative copies.

### Today (manual)

Create the two GitHub Apps manually via *Organization settings →
Developer settings → GitHub Apps → New GitHub App* with the
permissions above. Do **not** expect Stage 0 to consume GitHub App
credentials via `TF_VAR_*` env vars yet: `terraform/stages/0-fleet`
does not currently declare those inputs, so they would be ignored.
That wiring is planned for `PLAN.md` §16.4.

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
- Tenant role: **Privileged Role Administrator** (or Global
  Administrator) — required to grant the
  `Application Administrator` directory role to the
  `fleet-stage0` and `fleet-meta` UAMIs.
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

- Hub VNet (adopter-owned; `networking.hub.resource_id` in
  `_fleet.yaml`) already exists. `bootstrap/fleet` peers the mgmt
  VNet to it; `bootstrap/environment` peers each env-region VNet.
  `bootstrap/fleet` does **not** create a VNet from scratch in an
  adopter-owned subnet — it creates its own (`vnet-<fleet>-mgmt` in
  `rg-net-mgmt`) from `networking.vnets.mgmt.address_space` and
  carves `snet-pe-shared` + `snet-runners` out of it as the two
  reserved `/26`s of the first `/24`. The runner subnet is delegated
  to `Microsoft.App/environments` and egresses via the hub firewall
  (UDR ownership is adopter-side on the hub).
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
  the `fleet-stage0` / `fleet-meta` UAMIs for every subsequent re-run.
- **VNet-reachable workstation for every re-run**: jump host,
  Azure Bastion, or VPN into the fleet VNet. The tfstate SA is
  private-only after the first apply — Terraform cannot reach it
  from a laptop over the public internet.
- **First-apply-only escape hatch**: set
  `allow_public_state_during_bootstrap = true` for the very first
  `bootstrap/fleet` apply. This leaves the storage account's
  public endpoint Enabled (with `defaultAction = "Deny"` still in
  place) long enough to seed the PE and DNS zone group; flip it back
  to `false` on the second apply. Do not leave it on.

**GitHub**

- Fleet repo already exists (created via "Use this template" in
  §1); `bootstrap/fleet` adopts it via an `import` block.
- `GITHUB_TOKEN` exported with classic-PAT scopes `repo:admin`
  and `admin:org` (the latter only if `github_org` is an
  organization).
- The `fleet-meta` and `stage0-publisher` GitHub Apps from §4 are
  **not** required for the initial `bootstrap/fleet` apply — they
  become relevant for later workflows. Provide their credentials
  as `TF_VAR_*` env vars or in `./.gh-apps.auto.tfvars` at that
  point. `bootstrap/fleet` does not create, write, or manage the
  GitHub App credentials.
- The **`fleet-runners`** GitHub App **is** required up-front: the
  vendored runner module validates that
  `github_app.fleet_runners.{app_id, installation_id}` are non-empty
  when `authentication_method = "github_app"`, so
  `clusters/_fleet.yaml` must carry both numeric IDs before the
  first `bootstrap/fleet` apply. The PEM itself is resolved at
  runtime via Key Vault reference (Stage 0 seeds it), so its
  absence does not block the first apply — only scale-out of the
  runner pool.
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

# First apply — leave the tfstate SA's public endpoint Enabled long
# enough to seed the private endpoint + DNS zone group.
terraform apply -var allow_public_state_during_bootstrap=true

# Every subsequent apply (from a VNet-reachable workstation):
terraform apply
```

The fleet repo you created via "Use this template" already exists on
GitHub; `bootstrap/fleet` contains an `import` block for
`github_repository.fleet` that adopts it into state on the first apply.
No manual `terraform import` step is required.

See `PLAN.md` §4 Stage -1 for the full bootstrap sequence.

## Re-running `init-fleet.sh`

The script self-deletes after a successful run, so there is no
re-run path in the adopter repo. To change fleet-identity values
post-init, edit `clusters/_fleet.yaml` directly and re-apply the
bootstrap stages.
