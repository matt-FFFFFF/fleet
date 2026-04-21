# terraform-azurerm-avm-ptn-cicd-agents-and-runners (vendored)

Self-hosted CI/CD runner pool for Azure DevOps Agents and GitHub Runners
on Azure Container Apps (with KEDA autoscaling) or Azure Container
Instances.

> **Note for this repo.** This module is **vendored** into the fleet repo at
> `terraform/modules/cicd-runners/` from
> [`Azure/terraform-azurerm-avm-ptn-cicd-agents-and-runners`](https://github.com/Azure/terraform-azurerm-avm-ptn-cicd-agents-and-runners)
> at tag `v0.5.2` with repo-local extensions and trimmed scope (telemetry
> stripped, provider pins aligned, Key Vault reference for the GitHub App
> private key). See `VENDORING.md` for the full upstream delta. Internal
> callers **must** reference it via a relative in-repo path
> (`source = "../../modules/cicd-runners"`), not the upstream registry URL
> used in the examples below. The external `source = "Azure/..."` examples
> are retained verbatim from upstream so this README stays regeneratable
> via `terraform-docs`.

## Features

- Deploys Azure DevOps Agents with PAT or UAMI authentication.
- Deploys GitHub Runners with PAT or GitHub App authentication.
- Supports Azure Container Apps with KEDA autoscaling, or Azure
  Container Instances.
- Supports public or private networking.
- Creates all required Azure resources, or reuses existing ones.

## Local extensions vs upstream

Kept deliberately small so `git diff` against upstream stays readable.
Full details in `VENDORING.md`. Summary:

- **Key Vault reference for the GitHub App private key**: two new
  inputs, `github_app_key_kv_secret_id` and `github_app_key_identity_id`.
  When set, the `application-key` Container Apps secret is emitted in
  Key Vault-reference form (`{ name, keyVaultUrl, identity }`) instead
  of an inline value, so the PEM is resolved at runtime from Key Vault
  and never materialises in Terraform state.
- **Telemetry stripped**: no `modtm` provider, no `enable_telemetry`
  variable, no `main.telemetry.tf`.
- **Provider pins** rewritten to the repo-wide convention
  (pessimistic-minor, per AGENTS.md §6): Terraform `~> 1.14`,
  `hashicorp/azurerm ~> 4.20`, `Azure/azapi ~> 2.9`,
  `hashicorp/random ~> 3.8`, `hashicorp/time ~> 0.13`.

## Callers inside this repo

- `terraform/bootstrap/fleet/main.runner.tf` — the single shared
  repo-scoped GitHub runner pool used by `fleet-stage0` / `fleet-meta`
  and per-env `fleet-<env>` workflows. Uses GitHub App authentication
  with the private key sourced from Key Vault.
