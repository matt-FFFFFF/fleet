#!/usr/bin/env bash
# validate-subnet-slots.sh
#
# PR-check hook for PLAN §3.4 Phase F. Validates every
# `clusters/<env>/<region>/<name>/cluster.yaml` against the shared
# `clusters/_fleet.yaml`:
#
#   1. `networking.subnet_slot` is present and a non-negative integer.
#   2. The owning env-region exists in `_fleet.yaml` and has an
#      `address_space` from which we can derive capacity:
#         capacity = min(16, 2 * (2^(24-N) - 2))         # for A/N
#      (Two-pool layout: one /28 api subnet + one /25 nodes subnet per
#      cluster inside an N-prefix VNet; /20=16, /21=12, /22=4 etc.)
#   3. `subnet_slot` is within `[0, capacity-1]`.
#   4. `subnet_slot` is unique per `(env, region)` across all
#      cluster.yaml files.
#   5. (PR mode only — when `BASE_REF` is set to the PR base) For every
#      changed cluster.yaml, `git show ${BASE_REF}:<path>` must have the
#      same `subnet_slot` if the file existed on the base. Changing a
#      slot in place is disallowed (PLAN §3.4 immutability rule); the
#      operator has to re-create the cluster under a new slot.
#
# Dependencies: bash ≥ 4, `yq` (mikefarah, v4+), `git`.
# Exits 0 on success, 1 on any violation (all violations are printed
# before exit to maximise signal per run).
#
# The script mirrors `terraform/modules/fleet-identity/main.tf` L138's
# capacity formula exactly. If that formula changes, change this too
# (PLAN §3.4 parity rule; `docs/naming.md` is the third leg).

set -euo pipefail

readonly SCRIPT_NAME="validate-subnet-slots"
readonly FLEET_YAML="${FLEET_YAML:-clusters/_fleet.yaml}"
readonly CLUSTERS_GLOB="${CLUSTERS_GLOB:-clusters/*/*/*/cluster.yaml}"
readonly BASE_REF="${BASE_REF:-}"

errors=0

err() {
  printf '[%s] ERROR: %s\n' "$SCRIPT_NAME" "$*" >&2
  errors=$((errors + 1))
}

info() {
  printf '[%s] %s\n' "$SCRIPT_NAME" "$*" >&2
}

require() {
  command -v "$1" >/dev/null 2>&1 || {
    printf '[%s] FATAL: missing required tool: %s\n' "$SCRIPT_NAME" "$1" >&2
    exit 2
  }
}

# capacity_for_prefix <N>  →  min(16, 2 * (2^(24-N) - 2))
# Returns 0 for any N outside [16, 22]: /23 and /24 land inside the
# [16,24] sanity guard but yield capacity=0 under the two-pool formula
# (no room for reserved /24 + api /24 + at least one nodes /24);
# anything wider than /16 is well beyond any realistic fleet VNet and
# would be clamped to 16 by the min() if it got past the guard.
capacity_for_prefix() {
  local n="$1"
  if [[ ! "$n" =~ ^[0-9]+$ ]] || (( n < 16 || n > 24 )); then
    echo 0
    return
  fi
  local raw=$(( 2 * ((1 << (24 - n)) - 2) ))
  if (( raw > 16 )); then
    echo 16
  elif (( raw < 0 )); then
    echo 0
  else
    echo "$raw"
  fi
}

# address_space_for_env_region <env> <region>
# Reads `_fleet.yaml.networking.envs.<env>.regions.<region>.address_space`.
# Emits the scalar CIDR or empty string if absent.
address_space_for_env_region() {
  local env="$1" region="$2"
  yq -r ".networking.envs.\"$env\".regions.\"$region\".address_space // \"\"" "$FLEET_YAML"
}

require yq
require git

if [[ ! -f "$FLEET_YAML" ]]; then
  err "$FLEET_YAML not found — is the repo initialised? (run init-fleet.sh)"
  exit 1
fi

# -- Collect (env, region, name, slot, path) tuples from every cluster.yaml -

declare -A slot_by_env_region  # key: "<env>|<region>|<slot>" → path (for dup detection)

shopt -s nullglob
cluster_files=( $CLUSTERS_GLOB )
shopt -u nullglob

if (( ${#cluster_files[@]} == 0 )); then
  info "no cluster.yaml files found under $CLUSTERS_GLOB; nothing to validate"
  exit 0
fi

for path in "${cluster_files[@]}"; do
  # Derive (env, region, name) from the path layout. The layout is
  # always `<prefix>/<env>/<region>/<name>/cluster.yaml` where the
  # prefix is typically `clusters/` in-repo but may be any directory
  # when the validator is invoked over a scratch tree (tests). Pull
  # the four trailing components by repeated `dirname` / `basename`
  # so absolute paths work too.
  if [[ "$(basename "$path")" != "cluster.yaml" ]]; then
    err "$path: unexpected filename; expected .../cluster.yaml"
    continue
  fi
  name_dir="$(dirname "$path")"
  name="$(basename "$name_dir")"
  region_dir="$(dirname "$name_dir")"
  region="$(basename "$region_dir")"
  env_dir="$(dirname "$region_dir")"
  env="$(basename "$env_dir")"

  # --- Rule 1: subnet_slot present and non-negative integer -----------------
  slot="$(yq -r '.networking.subnet_slot // ""' "$path")"
  if [[ -z "$slot" || "$slot" == "null" ]]; then
    err "$path: networking.subnet_slot is missing (required; see PLAN §3.4 + docs/naming.md)"
    continue
  fi
  if [[ ! "$slot" =~ ^[0-9]+$ ]]; then
    err "$path: networking.subnet_slot=\"$slot\" is not a non-negative integer"
    continue
  fi
  # Force base-10: a quoted YAML value like "08" passes the digit regex
  # but bash arithmetic (( slot >= capacity )) below treats it as octal
  # and aborts with "value too great for base". Normalize here.
  slot=$((10#$slot))

  # --- Rule 2: owning env-region exists in _fleet.yaml ---------------------
  address_space="$(address_space_for_env_region "$env" "$region")"
  if [[ -z "$address_space" ]]; then
    err "$path: env-region $env/$region has no networking.envs.$env.regions.$region.address_space in $FLEET_YAML"
    continue
  fi

  # --- Rule 3: slot within [0, capacity-1] ---------------------------------
  prefix="${address_space##*/}"
  if [[ ! "$prefix" =~ ^[0-9]+$ ]]; then
    err "$path: address_space \"$address_space\" is not a valid CIDR (missing /N suffix)"
    continue
  fi
  capacity="$(capacity_for_prefix "$prefix")"
  if (( capacity == 0 )); then
    err "$path: env-region $env/$region address_space $address_space has zero cluster capacity (/$prefix yields capacity=0 under the two-pool formula min(16, 2*(2^(24-N)-2)); env-region VNets must be /22 or wider — /22=4, /21=12, /20=16)"
    continue
  fi
  if (( slot >= capacity )); then
    err "$path: subnet_slot=$slot is out of range [0,$((capacity - 1))] for $env/$region address_space $address_space (/$prefix → $capacity slots)"
    continue
  fi

  # --- Rule 4: uniqueness per (env, region) --------------------------------
  dup_key="$env|$region|$slot"
  if [[ -n "${slot_by_env_region[$dup_key]:-}" ]]; then
    err "$path: subnet_slot=$slot collides with ${slot_by_env_region[$dup_key]} (same env-region $env/$region)"
    continue
  fi
  slot_by_env_region[$dup_key]="$path"

  info "OK  $env/$region  slot=$slot  cap=$capacity  ($name)"
done

# --- Rule 5: immutability (PR mode) ------------------------------------------
#
# Only runs when BASE_REF is set (GitHub Actions passes the PR base).
# For every cluster.yaml in the cluster_files list that exists on the
# base ref, compare slot values. A file that is new on the branch (not
# present on base) is allowed to set any valid slot.

if [[ -n "$BASE_REF" ]]; then
  info "immutability check against base ref: $BASE_REF"
  for path in "${cluster_files[@]}"; do
    if ! base_content="$(git show "$BASE_REF:$path" 2>/dev/null)"; then
      continue  # new file on this branch; no base to compare
    fi
    base_slot="$(printf '%s\n' "$base_content" | yq -r '.networking.subnet_slot // ""')"
    head_slot="$(yq -r '.networking.subnet_slot // ""' "$path")"
    if [[ -n "$base_slot" && "$base_slot" != "$head_slot" ]]; then
      err "$path: subnet_slot changed from $base_slot (base $BASE_REF) to $head_slot — immutable per PLAN §3.4. To move a cluster to a new slot, re-create it under a new directory."
    fi
  done
fi

if (( errors > 0 )); then
  printf '\n[%s] FAIL: %d violation(s). See messages above.\n' "$SCRIPT_NAME" "$errors" >&2
  exit 1
fi

info "all cluster.yaml subnet_slot values valid"
