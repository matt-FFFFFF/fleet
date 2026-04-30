#!/usr/bin/env bash
# enable-pdns-internet-fallback.sh
#
# Iterates every private DNS zone in a hub resource group and sets
# `resolutionPolicy = NxDomainRedirect` on each of its vnet links.
# When the private zone returns NXDOMAIN for an A/AAAA/CNAME query
# (i.e. the queried name has no record in the private zone), Azure
# DNS falls back to public resolution.
#
# Why: many Azure platform services (Log Analytics, Storage, KeyVault,
# Container Registry, Monitor, etc.) share dual-purpose FQDNs that
# resolve to private endpoints when known and to public endpoints
# otherwise. With private DNS zones linked to a hub VNet but only
# *some* names actually present (because we only stamped PEs for the
# subset we use), unrelated resources in the same parent zone return
# NXDOMAIN and break — unless the link allows public fallback.
#
# `resolutionPolicy` is only valid on links to `privatelink.*` zones.
# Non-privatelink zones (e.g. a custom corp zone) are skipped.
#
# Idempotent: re-running on already-configured links is a no-op.
#
# Parallelism: the two `az` fan-outs (link enumeration per zone, and
# link updates) run in parallel via `xargs -P` capped at
# `${PARALLELISM:-8}` workers — well under ARM's per-subscription
# write throttling threshold (~30 concurrent for this endpoint
# family).
#
# Usage:
#   ./enable-pdns-internet-fallback.sh <hub-resource-group-id>
#   PARALLELISM=4 ./enable-pdns-internet-fallback.sh \
#     /subscriptions/<sub>/resourceGroups/rg-hub-primary-35ut

set -euo pipefail

if [[ $# -ne 1 ]]; then
  echo "usage: $0 <hub-resource-group-id>" >&2
  echo "  e.g. /subscriptions/<sub>/resourceGroups/rg-hub-primary-35ut" >&2
  exit 2
fi

rg_id="$1"
parallelism="${PARALLELISM:-8}"

# Parse subscription + RG out of the resource ID.
sub="$(awk -F/ '{print $3}' <<<"$rg_id")"
rg="$(awk -F/ '{print $5}' <<<"$rg_id")"

if [[ -z "$sub" || -z "$rg" ]]; then
  echo "error: could not parse subscription/resourceGroup from '$rg_id'" >&2
  exit 2
fi

echo "subscription: $sub"
echo "rg:           $rg"
echo "parallelism:  $parallelism"
echo

# --- Phase 0: list zones --------------------------------------------------
mapfile -t zones < <(
  az network private-dns zone list \
    --subscription "$sub" \
    -g "$rg" \
    --query "[].name" \
    -o tsv 2>/dev/null
)

if [[ "${#zones[@]}" -eq 0 ]]; then
  echo "no private DNS zones found in $rg_id" >&2
  exit 1
fi

echo "found ${#zones[@]} zone(s)"

privatelink_zones=()
skipped_nonpl=0
for z in "${zones[@]}"; do
  if [[ "$z" == privatelink.* ]]; then
    privatelink_zones+=("$z")
  else
    skipped_nonpl=$((skipped_nonpl + 1))
  fi
done

echo "  ${#privatelink_zones[@]} privatelink zone(s); $skipped_nonpl non-privatelink zone(s) skipped"
echo

if [[ "${#privatelink_zones[@]}" -eq 0 ]]; then
  echo "nothing to do."
  exit 0
fi

tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT

# --- Phase 1: enumerate links per zone (in parallel) ---------------------
#
# Output to $tmp/links.psv: <zone>|<link_name>|<current_policy>
#
# Pipe separator (not tab) is deliberate: BSD `xargs -I{}` collapses
# embedded tabs to spaces during interpolation, which corrupts a
# tab-delimited record into a single space-separated string. `|`
# survives interpolation intact. Resource names cannot contain `|`,
# so the separator is unambiguous.
echo "[phase 1] listing vnet links across ${#privatelink_zones[@]} zone(s)..."

printf '%s\n' "${privatelink_zones[@]}" \
  | xargs -P "$parallelism" -I{} bash -c '
      zone="$1"
      sub="$2"
      rg="$3"
      out="$4"
      az network private-dns link vnet list \
        --subscription "$sub" \
        -g "$rg" \
        -z "$zone" \
        --query "[].[name, resolutionPolicy]" \
        -o tsv 2>/dev/null \
      | awk -v z="$zone" -F"\t" '"'"'{print z "|" $1 "|" ($2 == "" ? "Default" : $2)}'"'"' \
      >>"$out"
    ' _ {} "$sub" "$rg" "$tmp/links.psv"

total_links=$(wc -l <"$tmp/links.psv" | tr -d ' ')
echo "  enumerated $total_links link(s)"
echo

# --- Phase 2: filter (skip already-correct) + update (in parallel) -------
#
# Pre-classify links; only those needing change are dispatched to az.
needs_update="$tmp/needs.psv"
already=0
: >"$needs_update"

while IFS='|' read -r zone link policy; do
  if [[ "$policy" == "NxDomainRedirect" ]]; then
    already=$((already + 1))
  else
    printf '%s|%s|%s\n' "$zone" "$link" "$policy" >>"$needs_update"
  fi
done <"$tmp/links.psv"

needed=$(wc -l <"$needs_update" | tr -d ' ')
echo "[phase 2] $already link(s) already NxDomainRedirect; $needed link(s) need update"

if [[ "$needed" -eq 0 ]]; then
  updated=0
  errors=0
else
  echo

  # Worker: read PSV line, run update, append result line to results file.
  # Result line shape: <status>|<zone>|<link>|<previous_policy>|<error>
  # `xargs -a FILE` is GNU-only; pipe via stdin for BSD/macOS portability.
  xargs -P "$parallelism" -I{} bash -c '
    line="$1"
    sub="$2"
    rg="$3"
    out="$4"
    IFS="|" read -r zone link policy <<<"$line"
    err_file="$(mktemp)"
    if az network private-dns link vnet update \
        --subscription "$sub" \
        -g "$rg" \
        -z "$zone" \
        -n "$link" \
        --resolution-policy NxDomainRedirect \
        -o none 2>"$err_file"; then
      printf "ok|%s|%s|%s|\n" "$zone" "$link" "$policy" >>"$out"
      printf "  [ok]   %s/%s  (was: %s)\n" "$zone" "$link" "$policy"
    else
      err="$(tr "\t\n|" "   " <"$err_file" | head -c 500)"
      printf "fail|%s|%s|%s|%s\n" "$zone" "$link" "$policy" "$err" >>"$out"
      printf "  [FAIL] %s/%s  (was: %s): %s\n" "$zone" "$link" "$policy" "$err" >&2
    fi
    rm -f "$err_file"
  ' _ {} "$sub" "$rg" "$tmp/results.psv" <"$needs_update"

  updated=$(awk -F'|' '$1=="ok"'   "$tmp/results.psv" | wc -l | tr -d ' ')
  errors=$(awk -F'|' '$1=="fail"' "$tmp/results.psv" | wc -l | tr -d ' ')
fi

echo
echo "summary:"
echo "  updated:                     $updated"
echo "  already NxDomainRedirect:    $already"
echo "  skipped (non-privatelink):   $skipped_nonpl"
echo "  errors:                      $errors"

[[ "${errors:-0}" -eq 0 ]]
