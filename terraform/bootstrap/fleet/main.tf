# bootstrap/fleet
#
# Human-run, one-time (per PLAN §4 Stage -1 `bootstrap/fleet/`). Creates:
#
#   1. rg-fleet-tfstate + sttfstateacmefleet + tfstate-fleet container
#   2. rg-fleet-shared (Stage 0 will land ACR + fleet KV here)
#   3. uami-fleet-stage0 + uami-fleet-meta + their FICs
#   4. Azure RBAC: fleet-stage0 Contributor on rg-fleet-shared + Blob
#      Contributor on tfstate-fleet; fleet-meta Blob Contributor on
#      tfstate-fleet. Subscription-scope assignments for fleet-meta are
#      deferred to bootstrap/environment (one per env subscription).
#   5. Entra `Application Administrator` on both UAMIs.
#   6. Fleet GitHub repo + branch protection; team-repo-template repo.
#   7. fleet-stage0 + fleet-meta GitHub environments with env variables.
#
# Files intentionally omitted from this stage (move to later stages):
#   - ACR, fleet KV → Stage 0
#   - Per-env state containers + env UAMIs → bootstrap/environment
#   - Fleet-meta GH App + stage0-publisher GH App minting → see main.github.tf
#     TODO comment; these are currently manual preconditions.

# All resources live in topic-specific files:
#   main.state.tf       state SA + container
#   main.identities.tf  UAMIs + FICs + RBAC + Entra role assignments
#   main.github.tf      repos + environments + variables
