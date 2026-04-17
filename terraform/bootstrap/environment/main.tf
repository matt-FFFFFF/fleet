# bootstrap/environment
#
# Per-env scaffolding (see PLAN §4.1). Invoked by .github/workflows/env-bootstrap.yaml
# under the `fleet-meta` environment (2-reviewer gate), one run per env.
#
# Resources are split across:
#   main.state.tf         per-env state container
#   main.identities.tf    uami-fleet-<env> + FIC + env-scoped RBAC + meta sub RBAC
#   main.observability.tf NSP + AMW + DCE + Grafana + PE + Action Group
#   main.github.tf        fleet-<env> GH environment + variables
