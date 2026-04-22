#!/usr/bin/env bash
# check-naming-parity.sh
#
# Assert that `terraform/config-loader/load.sh` (shell) and
# `terraform/modules/fleet-identity/` (HCL) emit identical names and
# CIDRs for every field they both compute. Per AGENTS.md rule 5, these
# two implementations are the derivation contract for `docs/naming.md`;
# any divergence breaks bootstrap ↔ stage parity and must fail CI.
#
# Strategy:
#   1. Apply the `.github/scripts/naming-parity/` throwaway TF module
#      against `clusters/_fleet.yaml` and capture `derived` +
#      `networking_derived` as JSON.
#   2. Enumerate every cluster directory under `clusters/`.
#   3. For each cluster, run `config-loader/load.sh` and extract:
#        - fleet-scope fields from `.fleet` / `.derived`
#        - env-region-scope fields from `.derived.networking`, keyed on
#          `<env>/<region>` into the HCL `networking_derived.envs` map.
#   4. Compare the overlap field-by-field; print a diff and exit 1 on
#      any mismatch. Cluster-scope fields (`snet_aks_{api,nodes}_*`,
#      per-cluster KV / DNS zone names) are loader-only and skipped.
#
# Usage:
#   .github/scripts/check-naming-parity.sh [fleet_yaml_path]
#
# Default fleet_yaml_path: ./clusters/_fleet.yaml. Template-mode callers
# (validate.yaml) render the yaml into a tmpdir from the selftest
# fixture and pass the rendered path.

set -euo pipefail

die()  { printf 'check-naming-parity: %s\n' "$*" >&2; exit 1; }
info() { printf 'check-naming-parity: %s\n' "$*" >&2; }

repo_root="$(cd "$(dirname "$0")/../.." && pwd)"
fleet_yaml="${1:-$repo_root/clusters/_fleet.yaml}"
harness_dir="$repo_root/.github/scripts/naming-parity"
loader="$repo_root/terraform/config-loader/load.sh"

[[ -f "$fleet_yaml" ]] || die "fleet yaml not found: $fleet_yaml"
[[ -x "$loader" ]]      || die "loader not executable: $loader"

command -v terraform >/dev/null || die "terraform required on PATH"
command -v jq        >/dev/null || die "jq required on PATH"
command -v yq        >/dev/null || die "yq required on PATH"

info "fleet_yaml   = $fleet_yaml"
info "harness_dir  = $harness_dir"

# ---- 1. Emit HCL derivations ------------------------------------------------
#
# `terraform init` is idempotent; reuse any existing .terraform/ cache.
if [[ ! -d "$harness_dir/.terraform" ]]; then
  terraform -chdir="$harness_dir" init -backend=false -no-color >/dev/null
fi

# `apply` is the cheapest way to materialise outputs from a pure-HCL
# module with variable inputs; no resources are declared.
terraform -chdir="$harness_dir" apply \
  -auto-approve -no-color \
  -var="fleet_yaml_path=$fleet_yaml" >/dev/null

hcl_derived="$(terraform -chdir="$harness_dir" output -json derived)"
hcl_netderived="$(terraform -chdir="$harness_dir" output -json networking_derived)"

# ---- 2. Enumerate clusters --------------------------------------------------
#
# clusters/<env>/<region>/<name>/cluster.yaml. `clusters/_*` (defaults,
# template) are skipped by the glob shape.
# Portable across GNU find (Linux CI) and BSD find (macOS dev): strip
# the trailing /cluster.yaml rather than relying on `-printf '%h\n'`.
mapfile -t cluster_paths < <(
  find "$repo_root/clusters" \
    -mindepth 4 -maxdepth 4 -name cluster.yaml | sed 's|/cluster\.yaml$||' | sort
)
[[ "${#cluster_paths[@]}" -gt 0 ]] || die "no clusters found under $repo_root/clusters/<env>/<region>/<name>/"

info "found ${#cluster_paths[@]} cluster(s)"

# ---- 3. Loader → normalised JSON for each cluster ---------------------------
#
# Field-name mapping between loader (`.derived.networking.*`) and HCL
# (`.networking_derived.envs["<env>/<region>"].*`). Only the overlap is
# compared; cluster-scope loader-only fields are ignored (there is no
# HCL counterpart — fleet-identity has no cluster input, by design).
#
# Loader key                       →  HCL key (under envs["<env>/<region>"])
#   env_vnet_name                      vnet_name
#   env_net_resource_group             rg_name
#   node_asg_name                      node_asg_name
#   nsg_pe_env_name                    nsg_pe_env_name
#   route_table_name                   route_table_name
#   peering_spoke_to_mgmt_name         peering_spoke_to_mgmt_name
#   peering_mgmt_to_spoke_name         peering_mgmt_to_spoke_name
#   hub_network_resource_id            hub_network_resource_id
#   egress_next_hop_ip                 egress_next_hop_ip
#   snet_pe_env_cidr                   snet_pe_env_cidr
#   cluster_slot_capacity              cluster_slot_capacity
#   snet_runners_cidr                  snet_runners_cidr
#   snet_pe_fleet_cidr                 snet_pe_fleet_cidr
#   nsg_pe_fleet_name                  nsg_pe_fleet_name
#   nsg_runners_name                   nsg_runners_name
#
# Fleet-scope comparisons (same for every cluster; we check once using
# the first cluster's loader output):
#   .derived.acr_login_server          derived to "<acr_name>.azurecr.io"
#   .fleet.fleet.name                  (sanity only — not a derivation)
# The loader doesn't re-emit .state_* / acr_* / fleet_kv_* verbatim
# (they flow from `_fleet.yaml` directly through the merged doc), so
# the HCL-side fleet-scope check here is ACR-login-server only; the
# rest are covered by fleet-identity unit tests + bootstrap validate.

errors=0
trace() { printf '  mismatch: %s\n    loader: %s\n    hcl:    %s\n' "$1" "$2" "$3" >&2; errors=$((errors + 1)); }

# Fleet-scope ACR login server: formula is `<acr_name>.azurecr.io` in
# loader; HCL `derived.acr_name` is the authoritative acr_name.
hcl_acr_name="$(jq -r '.acr_name' <<<"$hcl_derived")"
hcl_acr_login="${hcl_acr_name}.azurecr.io"

# Per-cluster comparisons.
for cp in "${cluster_paths[@]}"; do
  loader_json="$("$loader" "$cp")"

  env="$(jq -r '.cluster.env'    <<<"$loader_json")"
  region="$(jq -r '.cluster.region' <<<"$loader_json")"
  name="$(jq -r '.cluster.name'   <<<"$loader_json")"
  key="${env}/${region}"

  info "checking $key/$name"

  # --- Fleet-scope spot-check (ACR login server) ---
  ldr_acr_login="$(jq -r '.derived.acr_login_server' <<<"$loader_json")"
  if [[ "$ldr_acr_login" != "$hcl_acr_login" ]]; then
    trace "[$name] acr_login_server" "$ldr_acr_login" "$hcl_acr_login"
  fi

  # --- Env-region-scope ---
  hcl_entry="$(jq --arg k "$key" '.envs[$k] // null' <<<"$hcl_netderived")"
  if [[ "$hcl_entry" == "null" ]]; then
    trace "[$key] missing from HCL networking_derived.envs" "<present>" "<absent>"
    continue
  fi

  # Each comparison: (field-label, loader-jq, hcl-jq).
  # `jq -r` renders null as the literal string "null" consistently on
  # both sides so string comparison is safe.
  compare() {
    local label="$1" lexpr="$2" hexpr="$3"
    local lv hv
    lv="$(jq -r "$lexpr" <<<"$loader_json")"
    hv="$(jq -r "$hexpr" <<<"$hcl_entry")"
    if [[ "$lv" != "$hv" ]]; then
      trace "[$key/$name] $label" "$lv" "$hv"
    fi
  }

  compare "env_vnet_name"              '.derived.networking.env_vnet_name'              '.vnet_name'
  compare "env_net_resource_group"     '.derived.networking.env_net_resource_group'     '.rg_name'
  compare "node_asg_name"              '.derived.networking.node_asg_name'              '.node_asg_name'
  compare "nsg_pe_env_name"            '.derived.networking.nsg_pe_env_name'            '.nsg_pe_env_name'
  compare "route_table_name"           '.derived.networking.route_table_name'           '.route_table_name'
  compare "peering_spoke_to_mgmt_name" '.derived.networking.peering_spoke_to_mgmt_name' '.peering_spoke_to_mgmt_name'
  compare "peering_mgmt_to_spoke_name" '.derived.networking.peering_mgmt_to_spoke_name' '.peering_mgmt_to_spoke_name'
  compare "hub_network_resource_id"    '.derived.networking.hub_network_resource_id'    '.hub_network_resource_id'
  compare "egress_next_hop_ip"         '.derived.networking.egress_next_hop_ip'         '.egress_next_hop_ip'
  compare "snet_pe_env_cidr"           '.derived.networking.snet_pe_env_cidr'           '.snet_pe_env_cidr'
  compare "cluster_slot_capacity"      '.derived.networking.cluster_slot_capacity'      '.cluster_slot_capacity'
  compare "snet_runners_cidr"          '.derived.networking.snet_runners_cidr'          '.snet_runners_cidr'
  compare "snet_pe_fleet_cidr"         '.derived.networking.snet_pe_fleet_cidr'         '.snet_pe_fleet_cidr'
  compare "nsg_pe_fleet_name"          '.derived.networking.nsg_pe_fleet_name'          '.nsg_pe_fleet_name'
  compare "nsg_runners_name"           '.derived.networking.nsg_runners_name'           '.nsg_runners_name'
done

if [[ "$errors" -gt 0 ]]; then
  printf '\ncheck-naming-parity: %d mismatch(es) between config-loader/load.sh and modules/fleet-identity/.\n' "$errors" >&2
  printf 'check-naming-parity: update docs/naming.md, load.sh, and fleet-identity together (AGENTS.md rule 5).\n' >&2
  exit 1
fi

info "OK — load.sh and modules/fleet-identity/ agree on all shared derivations"
