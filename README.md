<!-- fleet:banner -->
> ⚠️ **This repository is a template.** Before doing anything else, run
> `./init-fleet.sh` from the repo root. The script collects adopter identity
> (fleet name, tenant, subscriptions, DNS root, …) and invokes a throwaway
> Terraform module in `init/` that renders `clusters/_fleet.yaml`,
> `.github/CODEOWNERS`, and a new `README.md`, then deletes itself along
> with `init/` and the selftest workflow. See [`docs/adoption.md`](./docs/adoption.md).
<!-- /fleet:banner -->

<!-- fleet:branding:start -->
# fleet

Monorepo for the AKS fleet: Terraform-driven cluster provisioning, per-cluster
ArgoCD bootstrap, platform GitOps, team tenancy via AppProjects, and
Kargo-driven promotion.
<!-- fleet:branding:end -->

**Authoritative design**: see [`PLAN.md`](./PLAN.md). This README is a map into
the repo; the plan is the source of truth for decisions and architecture.

## Layout (abridged; full tree in `PLAN.md` §2)

```
fleet/
├── PLAN.md
├── init-fleet.sh                 # one-shot adopter initializer (deleted after run)
├── init/                         # throwaway Terraform module used by init-fleet.sh (deleted after run)
├── clusters/                     # per-cluster config; directory path encodes env/region/name
│   ├── _fleet.yaml               # fleet-scope config (rendered by init/ on first run)
│   ├── _defaults.yaml            # fleet-wide defaults (merged bottom of the chain)
│   ├── _template/                # `cp -r` onboarding scaffold
│   ├── mgmt/<region>/<name>/cluster.yaml
│   ├── nonprod/<region>/<name>/cluster.yaml
│   └── prod/<region>/<name>/cluster.yaml
│
├── terraform/
│   ├── bootstrap/{fleet,environment,team}/   # seeds identity + GH scaffolding (see PLAN §4 Stage -1)
│   ├── stages/
│   │   ├── 0-fleet/                          # fleet-global (ACR, fleet KV, AAD apps, Kargo UAMI)
│   │   ├── 1-cluster/                        # per-cluster infra (AKS, UAMIs, cluster KV, DNS, DCR)
│   │   └── 2-kubernetes/                      # per-cluster in-cluster bootstrap (ArgoCD, FICs, ESO seeds)
│   ├── modules/
│   │   ├── aks-cluster/                      # Entra-only AVM wrapper
│   │   ├── cluster-identities/               # per-team + platform UAMIs
│   │   ├── argocd-bootstrap/                 # Phase 2
│   │   └── cluster-dns/                      # Phase 1 (DNS zone + links + role assignment)
│   └── config-loader/load.sh                 # yq deep-merge of the _defaults chain → tfvars.json
│
├── platform-gitops/                          # Argo source of truth (Phase 2+)
│
├── .github/
│   ├── workflows/{validate,tf-plan,tf-apply,env-bootstrap,team-bootstrap}.yaml
│   └── scripts/{mint-aks-token,lint-teams,publish-repo-var}.sh
│
└── docs/
    ├── adoption.md                           # adopter-facing: template → initialized repo
    ├── naming.md                             # canonical resource-name derivation spec
    ├── onboarding-cluster.md
    ├── onboarding-team.md
    ├── upgrades.md
    └── promotion.md
```

## Adopting this template

1. Click **Use this template → Create new repository** on GitHub.
2. Clone it locally and run `./init-fleet.sh`. The wrapper prompts for
   any values still set to `"__PROMPT__"` in `init/inputs.auto.tfvars`,
   then runs the `init/` Terraform module to render
   `clusters/_fleet.yaml`, `.github/CODEOWNERS`, and a new `README.md`.
3. The script deletes `init/`, itself, and the selftest workflow. Commit
   and push, then proceed to `terraform/bootstrap/fleet` per
   [`docs/adoption.md`](./docs/adoption.md).

## Current phase

Phase 1 scaffolding — see `PLAN.md` §13 / §16. Nothing in this repo has been
applied against a live Azure tenant yet; all code is first-cut scaffolding
derived from `PLAN.md`.

## Onboarding

- Operator flows: `docs/onboarding-cluster.md`, `docs/onboarding-team.md`,
  `docs/upgrades.md`, `docs/promotion.md`.
