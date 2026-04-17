# fleet

Monorepo for the AKS fleet: Terraform-driven cluster provisioning, per-cluster
ArgoCD bootstrap, platform GitOps, team tenancy via AppProjects, and
Kargo-driven promotion.

**Authoritative design**: see [`PLAN.md`](./PLAN.md). This README is a map into
the repo; the plan is the source of truth for decisions and architecture.

## Layout (abridged; full tree in `PLAN.md` §2)

```
fleet/
├── PLAN.md
├── clusters/                 # per-cluster config; directory path encodes env/region/name
│   ├── _fleet.yaml           # fleet-scope config (ACR, fleet KV, AAD, DNS root, per-env blocks)
│   ├── _defaults.yaml        # fleet-wide defaults (merged bottom of the chain)
│   ├── _template/            # `cp -r` onboarding scaffold
│   ├── mgmt/<region>/<name>/cluster.yaml
│   ├── nonprod/<region>/<name>/cluster.yaml
│   └── prod/<region>/<name>/cluster.yaml
│
├── terraform/
│   ├── bootstrap/{fleet,environment,team}/   # seeds identity + GH scaffolding (see PLAN §4 Stage -1)
│   ├── stages/
│   │   ├── 0-fleet/                          # fleet-global (ACR, fleet KV, AAD apps, Kargo UAMI)
│   │   ├── 1-cluster/                        # per-cluster infra (AKS, UAMIs, cluster KV, DNS, DCR)
│   │   └── 2-bootstrap/                      # per-cluster in-cluster bootstrap (ArgoCD, FICs, ESO seeds)
│   ├── modules/
│   │   ├── aks-cluster/                      # Entra-only AVM wrapper
│   │   ├── cluster-identities/               # per-team + platform UAMIs
│   │   ├── argocd-bootstrap/                 # Phase 2
│   │   └── cluster-dns/                      # Phase 1 (DNS zone + links + role assignment)
│   └── config-loader/load.sh                 # yq deep-merge of the _defaults chain → tfvars.json
│
├── platform-gitops/                          # Argo source of truth (Phase 2+)
│   ├── applications/
│   ├── components/
│   ├── kargo/
│   └── config/{clusters,teams}/
│
├── .github/
│   ├── workflows/{validate,tf-plan,tf-apply,env-bootstrap,team-bootstrap}.yaml
│   └── scripts/{mint-aks-token,lint-teams,publish-repo-var}.sh
│
└── docs/
```

## Current phase

Phase 1 scaffolding — see `PLAN.md` §13. Nothing in this repo has been applied
against a live Azure tenant yet; all code is unreviewed first-cut scaffolding
derived from `PLAN.md`.

## Onboarding

- Operator flows: `docs/onboarding-cluster.md`, `docs/onboarding-team.md`,
  `docs/upgrades.md`, `docs/promotion.md`.
