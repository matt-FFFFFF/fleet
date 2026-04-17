#!/usr/bin/env bash
# terraform/config-loader/load.sh
#
# Produce a single merged tfvars.json for a cluster by deep-merging the
# _defaults chain under its cluster.yaml, then layering in derived values.
#
# Usage:
#   load.sh <cluster-path>
#   load.sh clusters/nonprod/eastus/aks-nonprod-01
#
# Writes (stdout) a JSON document with the shape:
#   {
#     "fleet":     {...},   # from clusters/_fleet.yaml
#     "cluster":   {...},   # merged cluster config + derived .name/.env/.region
#     "kubernetes":{...},
#     "networking":{...},
#     "node_pools":{...},
#     "platform":  {...},
#     "teams":     [...],
#     "derived": {
#       "dns_zone_fqdn":             "...",
#       "dns_zone_resource_group":   "...",
#       "keyvault_name":             "...",
#       "keyvault_resource_group":   "...",
#       "acr_login_server":          "...",
#       "cluster_domain":            "..."
#     }
#   }
#
# Derivation rules: see PLAN.md §3.3.

set -euo pipefail

die() { printf 'load.sh: %s\n' "$*" >&2; exit 1; }

command -v yq >/dev/null 2>&1 || die "yq is required (https://github.com/mikefarah/yq)"
command -v jq >/dev/null 2>&1 || die "jq is required"

[[ $# -eq 1 ]] || die "usage: $0 <cluster-path>"

cluster_path="${1%/}"
[[ -f "$cluster_path/cluster.yaml" ]] || die "no cluster.yaml at $cluster_path"

# Resolve repo root = directory containing `clusters/`.
repo_root="$(cd "$cluster_path" && while [[ "$PWD" != "/" && ! -d "$PWD/clusters" ]]; do cd ..; done; pwd)"
[[ -d "$repo_root/clusters" ]] || die "could not locate repo root from $cluster_path"

rel="${cluster_path#$repo_root/}"
[[ "$rel" == clusters/* ]] || die "$cluster_path is not under $repo_root/clusters"

# Derive env / region / name from path: clusters/<env>/<region>/<name>/
IFS=/ read -r _clusters env region name _rest <<<"$rel/"
[[ -n "$env" && -n "$region" && -n "$name" ]] || die "path must be clusters/<env>/<region>/<name>"

fleet_file="$repo_root/clusters/_fleet.yaml"
[[ -f "$fleet_file" ]] || die "missing $fleet_file"

# Deep-merge chain, lowest precedence first, highest last.
chain=(
  "$repo_root/clusters/_defaults.yaml"
  "$repo_root/clusters/$env/_defaults.yaml"
  "$repo_root/clusters/$env/$region/_defaults.yaml"
  "$cluster_path/cluster.yaml"
)

# yq deep-merge: `*d` merges arrays by index, but we want later-wins-on-scalars
# and concat-on-arrays. Flag `*n` (override null), `*d` (deep). For Phase 1 the
# default `*d` override semantics suffice; arrays are currently scalar lists
# (zones, teams, dns_linked_vnet_ids) and are fully overridden by the nearest
# file — this is intentional.
existing=()
for f in "${chain[@]}"; do [[ -f "$f" ]] && existing+=("$f"); done

merged_yaml="$(yq eval-all '. as $item ireduce ({}; . * $item)' "${existing[@]}")"

# Pull fleet block separately — not merged, always full.
fleet_json="$(yq -o=json '.' "$fleet_file")"
merged_json="$(printf '%s' "$merged_yaml" | yq -o=json '.')"

# --- Derivations --------------------------------------------------------------

fleet_name="$(printf '%s' "$fleet_json" | jq -r '.fleet.name')"
fleet_root="$(printf '%s' "$fleet_json" | jq -r '.dns.fleet_root')"
dns_rg_pattern="$(printf '%s' "$fleet_json" | jq -r '.dns.resource_group_pattern // "rg-dns-{env}"')"
# ACR name: override else `acr<fleet.name>shared` — matches docs/naming.md
# and bootstrap/fleet/main.tf local.derived.acr_name.
acr_name="$(printf '%s' "$fleet_json" | jq -r --arg fn "$fleet_name" '
  (.acr.name_override // "") as $ov
  | (if $ov == "" then "acr" + $fn + "shared" else $ov end)
')"

dns_zone_fqdn="${name}.${region}.${env}.${fleet_root}"
dns_zone_rg="$(printf '%s' "$merged_json" | jq -r --arg p "$dns_rg_pattern" --arg env "$env" '
  .platform.dns.resource_group // ($p | sub("{env}"; $env))
')"

# KV name: override → else kv-<cluster.name>, truncated to 24 chars (Azure limit).
kv_name="$(printf '%s' "$merged_json" | jq -r --arg n "$name" '
  .platform.keyvault.name // ("kv-" + $n) | .[0:24]
')"
kv_rg="$(printf '%s' "$merged_json" | jq -r '.platform.keyvault.resource_group // empty')"
[[ -z "$kv_rg" ]] && kv_rg="$(printf '%s' "$merged_json" | jq -r '.cluster.resource_group')"

acr_login_server="${acr_name}.azurecr.io"
cluster_domain="$dns_zone_fqdn"

# subscription_id: pulled from _fleet.yaml.environments.<env> if the cluster
# file doesn't override. Env _defaults.yaml no longer carries this value;
# the single source of truth is _fleet.yaml (see PLAN §16).
cluster_sub="$(printf '%s' "$merged_json" | jq -r '.cluster.subscription_id // empty')"
if [[ -z "$cluster_sub" ]]; then
  cluster_sub="$(printf '%s' "$fleet_json" | jq -r --arg env "$env" '
    .environments[$env].subscription_id // empty
  ')"
  [[ -n "$cluster_sub" ]] || die "no subscription_id for env $env in _fleet.yaml"
fi

# --- Emit ---------------------------------------------------------------------
#
# Inject cluster.{name,env,region} as derived (not declared). Layer `derived`
# block. Pass `fleet` in full so Stage 1 can read `_fleet.yaml` env-scope
# blocks (environments.<env>.aks.admin_groups etc.) without a second load.

jq -n \
  --argjson merged "$merged_json" \
  --argjson fleet  "$fleet_json" \
  --arg name       "$name" \
  --arg env        "$env" \
  --arg region     "$region" \
  --arg dns_fqdn   "$dns_zone_fqdn" \
  --arg dns_rg     "$dns_zone_rg" \
  --arg kv_name    "$kv_name" \
  --arg kv_rg      "$kv_rg" \
  --arg acr_ls     "$acr_login_server" \
  --arg cl_domain  "$cluster_domain" \
  --arg cluster_sub "$cluster_sub" \
  '$merged
   | .cluster.name   = $name
   | .cluster.env    = $env
   | .cluster.region = $region
   | .cluster.subscription_id = $cluster_sub
   | .fleet = $fleet
   | .derived = {
       dns_zone_fqdn:           $dns_fqdn,
       dns_zone_resource_group: $dns_rg,
       keyvault_name:           $kv_name,
       keyvault_resource_group: $kv_rg,
       acr_login_server:        $acr_ls,
       cluster_domain:          $cl_domain
     }'
