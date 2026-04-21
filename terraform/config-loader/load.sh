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
#       "cluster_domain":            "...",
#       "networking": {
#         # Cluster's own env-region (uniform across envs incl. mgmt).
#         "subnet_slot":             <int>,
#         "env_vnet_name":           "vnet-<fleet>-<env>-<region>",
#         "env_net_resource_group":  "rg-net-<env>-<region>",
#         "snet_pe_env_name":        "snet-pe-env-<env>-<region>",
#         "snet_pe_env_cidr":        "<cidr>",
#         "snet_aks_api_name":       "snet-aks-api-<cluster>",
#         "snet_aks_api_cidr":       "<cidr>",
#         "snet_aks_nodes_name":     "snet-aks-nodes-<cluster>",
#         "snet_aks_nodes_cidr":     "<cidr>",
#         "node_asg_name":           "asg-nodes-<env>-<region>",
#         "nsg_pe_env_name":         "nsg-pe-env-<env>-<region>",
#         "route_table_name":        "rt-aks-<env>-<region>",
#         "cluster_slot_capacity":   <int>,
#
#         # Peer mgmt env-region (null when env=mgmt — clusters in
#         # mgmt share the mgmt VNet directly and don't peer).
#         "peer_mgmt_region":               "<region>" | null,
#         "peer_mgmt_vnet_name":            "vnet-<fleet>-mgmt-<region>" | null,
#         "peer_mgmt_net_resource_group":   "rg-net-mgmt-<region>" | null,
#         "peering_spoke_to_mgmt_name":     "peer-<env>-<region>-to-mgmt-<mgmt-region>" | null,
#         "peering_mgmt_to_spoke_name":     "peer-mgmt-<mgmt-region>-to-<env>-<region>" | null,
#
#         # Fleet-plane (mgmt env-region only; null on non-mgmt).
#         "snet_pe_fleet_name":      "snet-pe-fleet-<region>" | null,
#         "snet_pe_fleet_cidr":      "<cidr>" | null,
#         "snet_runners_name":       "snet-runners-<region>" | null,
#         "snet_runners_cidr":       "<cidr>" | null,
#         "nsg_pe_fleet_name":       "nsg-pe-fleet-<region>" | null,
#         "nsg_runners_name":        "nsg-runners-<region>" | null
#       }
#     }
#   }
#
# Derivation rules: see PLAN.md §3.3 and docs/naming.md. This script and
# `terraform/modules/fleet-identity/main.tf` are the parity contract;
# change both together.

set -euo pipefail

die() { printf 'load.sh: %s\n' "$*" >&2; exit 1; }

command -v yq >/dev/null 2>&1 || die "yq is required (https://github.com/mikefarah/yq)"
command -v jq >/dev/null 2>&1 || die "jq is required"
command -v python3 >/dev/null 2>&1 || die "python3 is required (used by derive_cluster_cidrs for CIDR math)"

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

# subscription_id: pulled from _fleet.yaml.envs.<env> if the cluster file
# doesn't override. Env _defaults.yaml no longer carries this value; the
# single source of truth is _fleet.yaml (PLAN §16, §3.1).
cluster_sub="$(printf '%s' "$merged_json" | jq -r '.cluster.subscription_id // empty')"
if [[ -z "$cluster_sub" ]]; then
  cluster_sub="$(printf '%s' "$fleet_json" | jq -r --arg env "$env" '
    .envs[$env].subscription_id // empty
  ')"
  [[ -n "$cluster_sub" ]] || die "no subscription_id for env $env in _fleet.yaml (envs.$env.subscription_id)"
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
# Pod IPs live in CGNAT (100.64.0.0/10) and are non-routable outside the
# cluster (CNI Overlay + Cilium). Every cluster reuses the same pod CIDR
# (100.64.0.0/16); cross-cluster disambiguation is handled by
# `_ResourceId` / cluster name in observability queries.
#
# Uniform-env-region model (PLAN §3.1/§3.4): every env INCLUDING mgmt
# lives under `networking.envs.<env>.regions.<region>`. Mgmt is not a
# singleton; it has its own address_space, VNet shell, and cluster-
# workload subnet pools like every other env. Additionally, mgmt
# env-regions host the fleet-plane zone (snet-pe-fleet + snet-runners)
# at the HIGH end of the address_space.
#
# `address_space` is a YAML list of CIDR strings (possibly empty until
# adopter fills it in). CIDR math uses the first entry.

# Adopter-supplied UDR next-hop IP for this env-region. Pulled from
# `_fleet.yaml`.networking.envs.<env>.regions.<region>.egress_next_hop_ip
# (PLAN §3.4). Null is the template-repo default; Stage 1 fails fast
# on null for regions that host clusters. Previously this field lived
# in clusters/<env>/<region>/_defaults.yaml; it now sits with the rest
# of the per-env-region networking config.
egress_next_hop_ip="$(printf '%s' "$fleet_json" | jq -r --arg env "$env" --arg region "$region" '
  .networking.envs[$env].regions[$region].egress_next_hop_ip // empty
')"

subnet_slot="$(printf '%s' "$merged_json" | jq -r '.networking.subnet_slot // empty')"
[[ -n "$subnet_slot" ]] || die "cluster.yaml at $cluster_path is missing required field networking.subnet_slot (see PLAN §3.4)"
case "$subnet_slot" in
  ''|*[!0-9]*) die "networking.subnet_slot must be a non-negative integer; got: $subnet_slot" ;;
esac
# Normalize leading zeros: a quoted YAML value like "08" passes the digit
# check above but would poison bash arithmetic (octal) and `jq --argjson`
# (invalid JSON number). Force base-10 reinterpretation here.
subnet_slot=$((10#$subnet_slot))

# Resolve this cluster's own env-region address_space. `address_space`
# is a YAML list per PLAN §3.1; we take the first entry for CIDR math.
# An absent or empty list yields "" which propagates as a no-CIDRs
# derivation (fields set to null). Non-mgmt clusters still require it;
# mgmt clusters use their own mgmt env-region block exactly the same way.
env_address_space="$(printf '%s' "$fleet_json" | jq -r --arg env "$env" --arg region "$region" '
  (.networking.envs[$env].regions[$region].address_space // []) as $as
  | if ($as | type) == "array" then ($as[0] // "")
    elif ($as | type) == "string" then $as
    else "" end
')"

# Resolve the mgmt region for this cluster's peering derivation.
# Non-mgmt clusters peer their env-region VNet to exactly one mgmt
# env-region. Match by region name if the mgmt env has a region of the
# same name; else fall back to the first mgmt region. Mirror of
# `modules/fleet-identity/main.tf` local.mgmt_regions lookup. For
# clusters where env=mgmt, the result is empty (mgmt clusters share
# the mgmt VNet directly and do not peer).
if [[ "$env" == "mgmt" ]]; then
  peer_mgmt_region=""
else
  peer_mgmt_region="$(printf '%s' "$fleet_json" | jq -r --arg region "$region" '
    ((.networking.envs.mgmt.regions // {}) | keys) as $mr
    | if ($mr | length) == 0 then ""
      elif ($mr | index($region)) != null then $region
      else $mr[0] end
  ')"
fi

# Resolve mgmt-env-region fleet-plane CIDRs when this cluster is itself
# in mgmt. Non-mgmt clusters leave these empty.
if [[ "$env" == "mgmt" ]]; then
  mgmt_own_address_space="$env_address_space"
else
  mgmt_own_address_space=""
fi

# CIDR math via python (portable; avoids a jq-only bit-twiddling dance).
# For cluster-workload address_space A = `<ip>/N`:
#   api pool   = 2nd /24 of A  (index 1)
#   nodes pool = /24s at index 2..slots_total-1 of A
#   pe-env     = first /26 of first /24 (index 0)
#   capacity   = min(16, 2 * (slots_total - 2))
#   cluster i  → snet-aks-api   = i-th /28 of api pool
#             → snet-aks-nodes = (i % 2)-th /25 of the (2 + i//2)-th /24 of A
# For mgmt-env-region, also:
#   fleet zone     = upper /(N+1) of A          (cidrsubnet(A, 1, 1))
#   snet-runners   = first /23 of fleet zone    (ACA-delegated)
#   snet-pe-fleet  = /26 at index 8 of fleet zone
derive_cluster_cidrs() {
  local address_space="$1" slot="$2" is_mgmt="$3"
  [[ -z "$address_space" ]] && { echo "{}" ; return ; }
  python3 - "$address_space" "$slot" "$is_mgmt" <<'PY'
import ipaddress, json, sys
try:
    net = ipaddress.ip_network(sys.argv[1], strict=True)
except ValueError as e:
    # strict=True rejects CIDRs with host bits set; also catches
    # malformed strings ("not-a-cidr", "10.0.0.0/33", etc.). Emit the
    # structured {error: ...} JSON the caller already expects rather
    # than letting set -euo pipefail abort with a Python traceback.
    print(json.dumps({"error": f"address_space {sys.argv[1]!r} is not a valid strict CIDR: {e}"}))
    sys.exit(0)
try:
    i = int(sys.argv[2])
except ValueError:
    print(json.dumps({"error": f"subnet_slot must be an integer; got: {sys.argv[2]!r}"}))
    sys.exit(0)
is_mgmt = sys.argv[3] == "1"
slots_total = 2 ** (24 - net.prefixlen)   # number of /24s in the VNet
if slots_total < 3:
    print(json.dumps({"error": f"VNet /{net.prefixlen} too small: needs at least /22 to host reserved + api pool + one nodes /24"}))
    sys.exit(0)
capacity = min(16, 2 * (slots_total - 2))
if i < 0 or i >= capacity:
    print(json.dumps({"error": f"slot {i} out of range [0, {capacity - 1}] for VNet /{net.prefixlen} (capacity={capacity})"}))
    sys.exit(0)
# Reserved /24 (index 0) → first /26 = snet-pe-env.
pe_env = list(list(net.subnets(new_prefix=24))[0].subnets(new_prefix=26))[0]
# API pool = 2nd /24 (index 1); carve 16 /28s.
api_pool  = list(net.subnets(new_prefix=24))[1]
api       = list(api_pool.subnets(new_prefix=28))[i]
# Nodes pool = /24s at indices 2..slots_total-1; each /24 yields 2 /25s.
nodes_24  = list(net.subnets(new_prefix=24))[2 + (i // 2)]
nodes     = list(nodes_24.subnets(new_prefix=25))[i % 2]
out = {
    "snet_pe_env_cidr":      str(pe_env),
    "snet_aks_api_cidr":     str(api),
    "snet_aks_nodes_cidr":   str(nodes),
    "cluster_slot_capacity": capacity,
}
if is_mgmt:
    # Fleet zone = upper /(N+1) of A. Within it:
    #   snet-runners  = first /23 of the fleet zone.
    #   snet-pe-fleet = /26 at index 8 of the fleet zone.
    # cidrsubnet(A, 1, 1) == second half of A at prefixlen+1.
    fleet_zone_prefix = net.prefixlen + 1
    fleet_zone = list(net.subnets(new_prefix=fleet_zone_prefix))[1]
    try:
        runners  = list(fleet_zone.subnets(new_prefix=23))[0]
        pe_fleet = list(fleet_zone.subnets(new_prefix=26))[8]
        out["snet_runners_cidr"]  = str(runners)
        out["snet_pe_fleet_cidr"] = str(pe_fleet)
    except (ValueError, IndexError) as e:
        # Fleet zone too small (e.g. /22 A → /23 fleet zone can't host
        # 9 /26s). Surface as an error — mgmt address_space must be /20
        # per PLAN §3.4.
        print(json.dumps({"error": f"mgmt address_space /{net.prefixlen} too small for fleet-plane zone (needs /20 or larger): {e}"}))
        sys.exit(0)
print(json.dumps(out))
PY
}

is_mgmt_flag=0
[[ "$env" == "mgmt" ]] && is_mgmt_flag=1

cluster_cidrs="$(derive_cluster_cidrs "$env_address_space" "$subnet_slot" "$is_mgmt_flag")"
if printf '%s' "$cluster_cidrs" | jq -e '.error' >/dev/null 2>&1; then
  err="$(printf '%s' "$cluster_cidrs" | jq -r '.error')"
  die "cluster $name networking.subnet_slot=$subnet_slot rejected against env $env/$region address_space '$env_address_space': $err"
fi

# Fleet-identity-parity names. Mirror of `networking_derived.envs` in
# terraform/modules/fleet-identity/main.tf; keep in sync.
#
# Cluster's own env-region (uniform across envs incl. mgmt).
env_vnet_name="vnet-${fleet_name}-${env}-${region}"
env_net_rg="rg-net-${env}-${region}"
snet_pe_env_name="snet-pe-env-${env}-${region}"
snet_aks_api_name="snet-aks-api-${name}"
snet_aks_nodes_name="snet-aks-nodes-${name}"
node_asg_name="asg-nodes-${env}-${region}"
nsg_pe_env_name="nsg-pe-env-${env}-${region}"
route_table_name="rt-aks-${env}-${region}"

# Peer mgmt env-region (null when env=mgmt).
if [[ -n "$peer_mgmt_region" ]]; then
  peer_mgmt_vnet_name="vnet-${fleet_name}-mgmt-${peer_mgmt_region}"
  peer_mgmt_net_rg="rg-net-mgmt-${peer_mgmt_region}"
  peering_spoke_to_mgmt_name="peer-${env}-${region}-to-mgmt-${peer_mgmt_region}"
  peering_mgmt_to_spoke_name="peer-mgmt-${peer_mgmt_region}-to-${env}-${region}"
else
  peer_mgmt_vnet_name=""
  peer_mgmt_net_rg=""
  peering_spoke_to_mgmt_name=""
  peering_mgmt_to_spoke_name=""
fi

# Fleet-plane names (mgmt env-region only).
if [[ "$env" == "mgmt" ]]; then
  snet_pe_fleet_name="snet-pe-fleet-${region}"
  snet_runners_name="snet-runners-${region}"
  nsg_pe_fleet_name="nsg-pe-fleet-${region}"
  nsg_runners_name="nsg-runners-${region}"
else
  snet_pe_fleet_name=""
  snet_runners_name=""
  nsg_pe_fleet_name=""
  nsg_runners_name=""
fi

# Pass raw CIDR strings through to Stage 1 so the stage can author the
# azapi subnet resources without re-parsing the env VNet's address_space.

# --- Emit ---------------------------------------------------------------------
#
# Inject cluster.{name,env,region} as derived (not declared). Layer `derived`
# block. Pass `fleet` in full so Stage 1 can read `_fleet.yaml` env-scope
# blocks (envs.<env>.aks.admin_groups etc.) without a second load.
#
# jq's `--arg` always produces a string; use a small helper in the
# template to convert the sentinel empty string to JSON null for the
# nullable fields.

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
  --arg env_net_rg "$env_net_rg" \
  --arg snet_pe_env "$snet_pe_env_name" \
  --arg snet_api   "$snet_aks_api_name" \
  --arg snet_nodes "$snet_aks_nodes_name" \
  --arg asg        "$node_asg_name" \
  --arg nsg_pe_env "$nsg_pe_env_name" \
  --arg rt_name    "$route_table_name" \
  --arg peer_mgmt_region   "$peer_mgmt_region" \
  --arg peer_mgmt_vnet     "$peer_mgmt_vnet_name" \
  --arg peer_mgmt_net_rg   "$peer_mgmt_net_rg" \
  --arg p_s2m      "$peering_spoke_to_mgmt_name" \
  --arg p_m2s      "$peering_mgmt_to_spoke_name" \
  --arg snet_pe_fleet "$snet_pe_fleet_name" \
  --arg snet_runners  "$snet_runners_name" \
  --arg nsg_pe_fleet  "$nsg_pe_fleet_name" \
  --arg nsg_runners   "$nsg_runners_name" \
  --arg egress_hop    "$egress_next_hop_ip" \
  --argjson slot   "$subnet_slot" \
  '
  # Empty-string → null helper.
  def orNull: if . == "" then null else . end;
  $merged
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
         subnet_slot:                   $slot,
         env_vnet_name:                 $env_vnet,
         env_net_resource_group:        $env_net_rg,
         snet_pe_env_name:              $snet_pe_env,
         snet_aks_api_name:             $snet_api,
         snet_aks_nodes_name:           $snet_nodes,
         node_asg_name:                 $asg,
         nsg_pe_env_name:               $nsg_pe_env,
         route_table_name:              $rt_name,
         peer_mgmt_region:              ($peer_mgmt_region | orNull),
         peer_mgmt_vnet_name:           ($peer_mgmt_vnet    | orNull),
         peer_mgmt_net_resource_group:  ($peer_mgmt_net_rg  | orNull),
         peering_spoke_to_mgmt_name:    ($p_s2m             | orNull),
         peering_mgmt_to_spoke_name:    ($p_m2s             | orNull),
         snet_pe_fleet_name:            ($snet_pe_fleet     | orNull),
         snet_runners_name:             ($snet_runners      | orNull),
         nsg_pe_fleet_name:             ($nsg_pe_fleet     | orNull),
         nsg_runners_name:              ($nsg_runners      | orNull),
         egress_next_hop_ip:            ($egress_hop       | orNull)
       } + $cidrs)
     }'
