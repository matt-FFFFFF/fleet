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

# --- Networking derivations (PLAN §3.4) ---------------------------------------
#
# Fleet-scope + env-scope names parallel `modules/fleet-identity/main.tf`
# (parity contract; see docs/naming.md). Cluster-scope per-subnet CIDRs
# are carved from two disjoint pools inside the env VNet's /N
# address_space, both indexed by the cluster's `networking.subnet_slot`:
#
#   API pool   = second /24 of env VNet   → 16 × /28 (AKS api-server delegated)
#   nodes pool = third /24 onward         → 2 × /25 per /24 (CNI-Overlay nodes)
#
# Pod IPs live in CGNAT (100.64.0.0/10), independent of the VNet address
# plan. Each env-region reserves a /12 via its `pod_cidr_slot`, and every
# cluster gets a /16 keyed on `subnet_slot`:
#
#   pod_cidr = 100.[64 + pod_cidr_slot * 16 + subnet_slot].0.0/16
#
# Silence-on-absence: pre-Phase-B `_fleet.yaml` renders lack
# `networking.vnets.mgmt` / `networking.envs` — those fields drop
# through as null and Stage 1 must precondition-check before using.

subnet_slot="$(printf '%s' "$merged_json" | jq -r '.networking.subnet_slot // empty')"
[[ -n "$subnet_slot" ]] || die "cluster.yaml at $cluster_path is missing required field networking.subnet_slot (see PLAN §3.4)"
case "$subnet_slot" in
  ''|*[!0-9]*) die "networking.subnet_slot must be a non-negative integer; got: $subnet_slot" ;;
esac

mgmt_address_space="$(printf '%s' "$fleet_json" | jq -r '.networking.vnets.mgmt.address_space // empty')"
env_address_space="$(printf '%s' "$fleet_json" | jq -r --arg env "$env" --arg region "$region" '
  .networking.envs[$env].regions[$region].address_space // empty
')"
env_pod_cidr_slot="$(printf '%s' "$fleet_json" | jq -r --arg env "$env" --arg region "$region" '
  .networking.envs[$env].regions[$region].pod_cidr_slot // empty
')"

# CIDR math via python (portable; avoids a jq-only bit-twiddling dance).
# For address_space A = `<ip>/N`:
#   api pool   = 2nd /24 of A  (index 1)
#   nodes pool = /24s at index 2..slots_total-1 of A
#   capacity   = min(16, 2 * (slots_total - 2))
#   cluster i  → snet-aks-api   = i-th /28 of api pool
#             → snet-aks-nodes = (i % 2)-th /25 of the (2 + i//2)-th /24 of A
# Pod CIDR (CGNAT):
#   pod_cidr = 100.[64 + pod_cidr_slot*16 + i].0.0/16
#   (null when env_pod_cidr_slot is unset — stage preconditions catch)
derive_cluster_cidrs() {
  local address_space="$1" slot="$2" pod_cidr_slot="$3"
  [[ -z "$address_space" ]] && { echo "{}" ; return ; }
  python3 - "$address_space" "$slot" "$pod_cidr_slot" <<'PY'
import ipaddress, json, sys
net = ipaddress.ip_network(sys.argv[1], strict=True)
i = int(sys.argv[2])
pod_slot_raw = sys.argv[3]
slots_total = 2 ** (24 - net.prefixlen)   # number of /24s in the VNet
if slots_total < 3:
    print(json.dumps({"error": f"VNet /{net.prefixlen} too small: needs at least /22 to host reserved + api pool + one nodes /24"}))
    sys.exit(0)
capacity = min(16, 2 * (slots_total - 2))
if i < 0 or i >= capacity:
    print(json.dumps({"error": f"slot {i} out of range [0, {capacity - 1}] for VNet /{net.prefixlen} (capacity={capacity})"}))
    sys.exit(0)
# API pool = 2nd /24 (index 1); carve 16 /28s.
api_pool  = list(net.subnets(new_prefix=24))[1]
api       = list(api_pool.subnets(new_prefix=28))[i]
# Nodes pool = /24s at indices 2..slots_total-1; each /24 yields 2 /25s.
nodes_24  = list(net.subnets(new_prefix=24))[2 + (i // 2)]
nodes     = list(nodes_24.subnets(new_prefix=25))[i % 2]
out = {
    "snet_aks_api_cidr":     str(api),
    "snet_aks_nodes_cidr":   str(nodes),
    "cluster_slot_capacity": capacity,
}
# Pod CIDR derivation (CGNAT 100.64.0.0/10). Env-region's pod_cidr_slot
# gates the entire derivation — absent → null passthrough so the loader
# still produces parseable tfvars for pre-Phase-B _fleet.yaml; Stage 1
# precondition-checks non-null before reading.
if pod_slot_raw:
    try:
        pod_slot = int(pod_slot_raw)
    except ValueError:
        print(json.dumps({"error": f"pod_cidr_slot for env region must be an integer; got: {pod_slot_raw!r}"}))
        sys.exit(0)
    if pod_slot < 0 or pod_slot > 15:
        print(json.dumps({"error": f"pod_cidr_slot {pod_slot} out of range [0, 15]"}))
        sys.exit(0)
    third_octet = 64 + pod_slot * 16 + i
    if third_octet > 127:
        print(json.dumps({"error": f"pod_cidr third octet {third_octet} exceeds CGNAT upper bound 127; shrink pod_cidr_slot or subnet_slot"}))
        sys.exit(0)
    out["pod_cidr"] = f"100.{third_octet}.0.0/16"
    out["pod_cidr_slot"] = pod_slot
else:
    out["pod_cidr"] = None
    out["pod_cidr_slot"] = None
print(json.dumps(out))
PY
}

cluster_cidrs="$(derive_cluster_cidrs "$env_address_space" "$subnet_slot" "$env_pod_cidr_slot")"
if printf '%s' "$cluster_cidrs" | jq -e '.error' >/dev/null 2>&1; then
  err="$(printf '%s' "$cluster_cidrs" | jq -r '.error')"
  die "cluster $name networking.subnet_slot=$subnet_slot rejected against env $env/$region address_space '$env_address_space': $err"
fi

# Fleet-identity-parity names. Mirror of `networking_derived` in
# terraform/modules/fleet-identity/main.tf; keep in sync.
env_vnet_name="vnet-${fleet_name}-${env}-${region}"
mgmt_vnet_name="vnet-${fleet_name}-mgmt"
env_net_rg="rg-net-${env}"
mgmt_net_rg="rg-net-mgmt"
node_asg_name="asg-nodes-${env}-${region}"
peering_env_to_mgmt="peer-${env}-${region}-to-mgmt"
peering_mgmt_to_env="peer-mgmt-to-${env}-${region}"
snet_aks_api_name="snet-aks-api-${name}"
snet_aks_nodes_name="snet-aks-nodes-${name}"

# Pass raw CIDR strings through to Stage 1 so the stage can author the
# azapi subnet resources without re-parsing the env VNet's address_space.

# --- Emit ---------------------------------------------------------------------
#
# Inject cluster.{name,env,region} as derived (not declared). Layer `derived`
# block. Pass `fleet` in full so Stage 1 can read `_fleet.yaml` env-scope
# blocks (environments.<env>.aks.admin_groups etc.) without a second load.

jq -n \
  --argjson merged "$merged_json" \
  --argjson fleet  "$fleet_json" \
  --argjson cidrs  "$cluster_cidrs" \
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
  --arg env_vnet   "$env_vnet_name" \
  --arg mgmt_vnet  "$mgmt_vnet_name" \
  --arg env_net_rg "$env_net_rg" \
  --arg mgmt_net_rg "$mgmt_net_rg" \
  --arg asg        "$node_asg_name" \
  --arg p_e2m      "$peering_env_to_mgmt" \
  --arg p_m2e      "$peering_mgmt_to_env" \
  --arg snet_api   "$snet_aks_api_name" \
  --arg snet_nodes "$snet_aks_nodes_name" \
  --argjson slot   "$subnet_slot" \
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
       cluster_domain:          $cl_domain,
       networking: ({
         subnet_slot:           $slot,
         env_vnet_name:         $env_vnet,
         env_net_resource_group: $env_net_rg,
         mgmt_vnet_name:        $mgmt_vnet,
         mgmt_net_resource_group: $mgmt_net_rg,
         node_asg_name:         $asg,
         peering_env_to_mgmt_name: $p_e2m,
         peering_mgmt_to_env_name: $p_m2e,
         snet_aks_api_name:     $snet_api,
         snet_aks_nodes_name:   $snet_nodes
       } + $cidrs)
     }'
