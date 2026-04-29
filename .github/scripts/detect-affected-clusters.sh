#!/usr/bin/env bash
# detect-affected-clusters.sh
#
# Emits JSON of clusters affected by the current change set, consumed by
# the `tf-plan.yaml` / `tf-apply.yaml` matrix step. Shape:
#
#   {
#     "stage0":   true|false,                        # true → a `stages/0-fleet` leg runs
#     "clusters": [                                  # one matrix leg per entry
#       { "path": "clusters/nonprod/eastus/aks-nonprod-01",
#         "env":  "nonprod",
#         "region": "eastus",
#         "name": "aks-nonprod-01" },
#       ...
#     ]
#   }
#
# Change-detection rules (PLAN §10 "Path filters"):
#
#   - `terraform/stages/0-fleet/**` changed                 → stage0=true.
#   - `terraform/stages/{1-cluster,2-kubernetes}/**` changed → every cluster
#     in `clusters/**/cluster.yaml` is affected (code-path change).
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
#     + stage0 (workflow change; re-plan everything).
#   - `clusters/_template/**`                                → ignored (not
#     a real cluster).
#
# Usage:
#   BASE_REF=origin/main HEAD_REF=HEAD ./detect-affected-clusters.sh
#
# If BASE_REF is empty (e.g. push to main with no predecessor diff), the
# script falls back to the full cluster set + stage0=true — safe superset.

set -euo pipefail

BASE_REF="${BASE_REF:-}"
HEAD_REF="${HEAD_REF:-HEAD}"

# --- Emit JSON object per cluster.yaml path, one per line -------------------
# Input: lines of `clusters/<env>/<region>/<name>/cluster.yaml` on stdin.
# Output: one compact JSON object per line.
path_to_json() {
  while IFS= read -r path; do
    [[ -z "$path" ]] && continue
    dir="${path%/cluster.yaml}"
    # dir = clusters/<env>/<region>/<name>
    IFS='/' read -r _ env region name <<<"$dir"
    jq -cn --arg path "$dir" --arg env "$env" --arg region "$region" --arg name "$name" \
      '{path:$path, env:$env, region:$region, name:$name}'
  done
}

# --- All cluster.yaml paths in the tree (excluding _template) ---------------
all_cluster_paths() {
  find clusters -mindepth 4 -maxdepth 4 -name cluster.yaml -print 2>/dev/null \
    | grep -v '^clusters/_template/' \
    | sort
}

# --- Full fallback (everything) ---------------------------------------------
if [[ -z "$BASE_REF" ]]; then
  echo >&2 "detect-affected-clusters: no BASE_REF; returning full set."
  clusters_json="$(all_cluster_paths | path_to_json | jq -cs .)"
  jq -cn --argjson c "$clusters_json" '{stage0:true, clusters:$c}'
  exit 0
fi

# --- Classify changed files -------------------------------------------------
changed="$(git diff --name-only "$BASE_REF" "$HEAD_REF" -- || true)"

stage0=false
everything=false
declare -a env_scopes=()
declare -a env_region_scopes=()
declare -a explicit_clusters=()

while IFS= read -r f; do
  [[ -z "$f" ]] && continue
  case "$f" in
    terraform/stages/0-fleet/*)
      stage0=true ;;
    terraform/stages/1-cluster/*|terraform/stages/2-kubernetes/*|terraform/modules/*)
      everything=true ;;
    .github/workflows/tf-plan.yaml|.github/workflows/tf-apply.yaml)
      everything=true
      stage0=true ;;
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
    } | sort -u | grep -v '^clusters/_template/' || true
  )"
fi

clusters_json="$(echo "$paths" | path_to_json | jq -cs .)"
jq -cn --argjson s0 "$stage0" --argjson c "${clusters_json:-[]}" \
  '{stage0:$s0, clusters:$c}'
