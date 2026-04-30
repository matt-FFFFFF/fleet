#!/usr/bin/env bash
# detect-affected-clusters.sh
#
# Emits JSON of clusters affected by the current change set, consumed by
# the `tf-plan.yaml` / `tf-apply.yaml` matrix step. Shape:
#
#   {
#     "clusters": [                                  # one matrix leg per entry
#       { "path": "clusters/nonprod/eastus/aks-nonprod-01",
#         "env":  "nonprod",
#         "region": "eastus",
#         "name": "aks-nonprod-01",
#         "role": "workload" },
#       ...
#     ]
#   }
#
# `role` is parsed from the cluster's `cluster.yaml` (`cluster.role`,
# defaulting to `"workload"`) so that workflow gates can distinguish the
# fleet's single management cluster (PLAN §1: hard-limit one mgmt
# cluster) from workload clusters without re-reading `cluster.yaml` from
# the workflow leg. The mgmt-only repo-var publish step in
# `tf-apply.yaml` keys off `matrix.cluster.role == 'management'`.
#
# Change-detection rules (PLAN §10 "Path filters"):
#
#   - `terraform/stages/{1-cluster,2-kubernetes}/**` changed → every
#     cluster in `clusters/**/cluster.yaml` is affected (code-path
#     change).
#   - `terraform/modules/**` changed                         → every cluster
#     affected (code-path change).
#   - `clusters/_fleet.yaml` or `clusters/_defaults.yaml` changed → all
#     clusters.
#   - `clusters/<env>/_defaults.yaml` changed                → all clusters
#     under that env.
#   - `clusters/<env>/<region>/_defaults.yaml` changed       → all clusters
#     under that env+region.
#   - `clusters/<env>/<region>/<name>/cluster.yaml` changed  → that cluster
#     alone.
#   - `.github/workflows/tf-plan.yaml` or `.github/workflows/tf-apply.yaml`
#     changed                                                → all clusters
#     (workflow change; re-plan everything).
#   - `clusters/_template/**`                                → ignored (not
#     a real cluster).
#
# Usage:
#   BASE_REF=origin/main HEAD_REF=HEAD ./detect-affected-clusters.sh
#
# If BASE_REF is empty (e.g. push to main with no predecessor diff), the
# script falls back to the full cluster set — safe superset.

set -euo pipefail

BASE_REF="${BASE_REF:-}"
HEAD_REF="${HEAD_REF:-HEAD}"

# --- Emit JSON object per cluster.yaml path, one per line -------------------
# Input: lines of `clusters/<env>/<region>/<name>/cluster.yaml` on stdin.
# Output: one compact JSON object per line.
#
# `role` is read from each cluster.yaml via `yq` (`.cluster.role //
# "workload"`). `yq` is part of the runner image; if absent, the role
# defaults to `"workload"` and the call exits 0 without setting it (the
# downstream gate keys off `== 'management'`, so missing role can never
# accidentally publish mgmt repo vars).
path_to_json() {
  while IFS= read -r path; do
    [[ -z "$path" ]] && continue
    dir="${path%/cluster.yaml}"
    # dir = clusters/<env>/<region>/<name>
    IFS='/' read -r _ env region name <<<"$dir"
    role="$(yq -r '.cluster.role // "workload"' "$path" 2>/dev/null || echo "workload")"
    jq -cn --arg path "$dir" --arg env "$env" --arg region "$region" \
      --arg name "$name" --arg role "$role" \
      '{path:$path, env:$env, region:$region, name:$name, role:$role}'
  done
}

# --- All cluster.yaml paths in the tree (excluding _template) ---------------
#
# `awk` is preferred over `grep -v` here: an adopter on day one has zero
# clusters under `clusters/<env>/<region>/<name>/`, so the pipeline emits
# no lines, which causes `grep -v` to exit 1 and (under `set -o pipefail`)
# kill the script before it can emit the empty-set JSON. `awk` returns 0
# regardless of how many lines matched.
all_cluster_paths() {
  find clusters -mindepth 4 -maxdepth 4 -name cluster.yaml -print 2>/dev/null \
    | awk '!/^clusters\/_template\//' \
    | sort
}

# --- Full fallback (everything) ---------------------------------------------
if [[ -z "$BASE_REF" ]]; then
  echo >&2 "detect-affected-clusters: no BASE_REF; returning full set."
  clusters_json="$(all_cluster_paths | path_to_json | jq -cs .)"
  jq -cn --argjson c "$clusters_json" '{clusters:$c}'
  exit 0
fi

# --- Classify changed files -------------------------------------------------
changed="$(git diff --name-only "$BASE_REF" "$HEAD_REF" -- || true)"

everything=false
declare -a env_scopes=()
declare -a env_region_scopes=()
declare -a explicit_clusters=()

while IFS= read -r f; do
  [[ -z "$f" ]] && continue
  case "$f" in
    terraform/stages/1-cluster/*|terraform/stages/2-kubernetes/*|terraform/modules/*)
      everything=true ;;
    .github/workflows/tf-plan.yaml|.github/workflows/tf-apply.yaml)
      everything=true ;;
    clusters/_fleet.yaml|clusters/_defaults.yaml)
      everything=true ;;
    clusters/_template/*)
      : ;;
    clusters/*/_defaults.yaml)
      env="${f#clusters/}"; env="${env%%/*}"
      env_scopes+=("$env") ;;
    clusters/*/*/_defaults.yaml)
      rest="${f#clusters/}"; env_region_scopes+=("${rest%/_defaults.yaml}") ;;
    clusters/*/*/*/cluster.yaml)
      rest="${f#clusters/}"; explicit_clusters+=("${rest%/cluster.yaml}") ;;
  esac
done <<<"$changed"

# --- Resolve the affected-cluster path list --------------------------------
if $everything; then
  paths="$(all_cluster_paths)"
else
  paths="$(
    {
      for env in "${env_scopes[@]+"${env_scopes[@]}"}"; do
        find "clusters/$env" -mindepth 3 -maxdepth 3 -name cluster.yaml -print 2>/dev/null || true
      done
      for er in "${env_region_scopes[@]+"${env_region_scopes[@]}"}"; do
        find "clusters/$er" -mindepth 2 -maxdepth 2 -name cluster.yaml -print 2>/dev/null || true
      done
      for c in "${explicit_clusters[@]+"${explicit_clusters[@]}"}"; do
        [[ -f "clusters/$c/cluster.yaml" ]] && echo "clusters/$c/cluster.yaml"
      done
    } | sort -u | awk '!/^clusters\/_template\//'
  )"
fi

clusters_json="$(echo "$paths" | path_to_json | jq -cs .)"
jq -cn --argjson c "${clusters_json:-[]}" \
  '{clusters:$c}'
