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

| Variable               | Description                                         |
| ---------------------- | --------------------------------------------------- |
| `fleet_name`           | Short slug, ≤12 chars, used in resource naming.     |
| `fleet_display_name`   | Human-friendly name for README + Grafana.           |
| `tenant_id`            | Entra tenant GUID.                                  |
| `github_org`           | GitHub org/user owning the fleet repo.              |
| `github_repo`          | Fleet repo name (default `platform-fleet`).         |
| `team_template_repo`   | Team template repo name (default `team-repo-template`). |
| `primary_region`       | Default Azure region (default `eastus`).            |
| `sub_shared`           | Subscription GUID for shared (ACR, state, fleet KV).|
| `sub_mgmt`             | Subscription GUID for mgmt env.                     |
| `sub_nonprod`          | Subscription GUID for nonprod env.                  |
| `sub_prod`             | Subscription GUID for prod env.                     |
| `dns_fleet_root`       | Parent private DNS zone (e.g. `int.acme.example`).  |

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
- Per-env `networking.grafana_pe_subnet_id`, `grafana_pe_linked_vnet_ids`.

Commit the initialized repo:

```sh
git add -A
git commit -m "chore: initialize fleet from template"
git push
```

## 4. Bootstrap Terraform

Proceed with `terraform/bootstrap/fleet` (human-run, once):

```sh
cd terraform/bootstrap/fleet
az login                              # tenant-admin + subscription-owner
export GITHUB_TOKEN=<PAT org:admin + repo:admin>
terraform init
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
