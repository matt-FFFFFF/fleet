#!/usr/bin/env bash
# schemas/tests/test.sh — exercise fleet.v1 and cluster.v1 schemas against
# curated valid/ and invalid/ fixtures.
#
# Tooling:
#   yq      — YAML → JSON conversion (mikefarah, the Go one)
#   ajv     — JSON Schema Draft 2020-12 validator (npx ajv-cli, no install)
#
# Exit code: 0 = all assertions held, 1 = at least one assertion failed.
#
# CI invokes this from the schema-lint job in .github/workflows/validate.yaml.
# Local devs can run it directly: `schemas/tests/test.sh`.

set -uo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
schemas_dir="$repo_root/schemas"
tests_dir="$schemas_dir/tests"

red()   { printf '\033[31m%s\033[0m\n' "$*"; }
green() { printf '\033[32m%s\033[0m\n' "$*"; }
gray()  { printf '\033[90m%s\033[0m\n' "$*"; }

# Resolve once; reuse for every fixture so npm doesn't probe the network
# repeatedly. ajv-cli@5 supports Draft 2020-12. `--strict-types=false`
# silences the noise about `type: [string, null]` unions (which we use
# deliberately for nullable scalars; ajv treats them as "non-strict" by
# default but still validates them correctly at runtime).
ajv() {
  npx --yes -p ajv-cli@5 -p ajv-formats@3 -- ajv "$@"
}

# Validate one yaml file against one schema. Echo PASS/FAIL with a short
# tag so test output stays scannable. Returns 0 on success, 1 on failure.
validate() {
  local schema="$1" yaml_file="$2" expected="$3" # expected ∈ {valid,invalid}
  # ajv-cli infers format from extension; force `.json` so it parses as
  # JSON rather than re-trying YAML on its own (which chokes on the
  # nested-flow output yq produces).
  local tmp
  tmp="$(mktemp -t schema-test).json" || return 1
  if ! yq -o=json '.' "$yaml_file" > "$tmp" 2>/dev/null; then
    red "  YQ-FAIL  $(basename "$yaml_file") — yaml parse failed"
    rm -f "$tmp"
    return 1
  fi
  local out rc
  out="$(ajv validate \
    --spec=draft2020 \
    --strict-types=false \
    -c ajv-formats \
    -s "$schema" \
    -d "$tmp" 2>&1)"
  rc=$?
  rm -f "$tmp"
  if [[ "$expected" == valid && $rc -eq 0 ]]; then
    green "  PASS     $(basename "$yaml_file")"
    return 0
  fi
  if [[ "$expected" == invalid && $rc -ne 0 ]]; then
    green "  PASS     $(basename "$yaml_file") (rejected as expected)"
    gray  "           $(printf '%s' "$out" | head -1)"
    return 0
  fi
  red "  FAIL     $(basename "$yaml_file") (expected $expected)"
  printf '%s\n' "$out" | sed 's/^/             /'
  return 1
}

# Run all fixtures under one suite (fleet/ or cluster/).
run_suite() {
  local suite="$1" schema="$2"
  local valid_dir="$tests_dir/$suite/valid"
  local invalid_dir="$tests_dir/$suite/invalid"
  local fails=0
  printf '\n== %s ==\n' "$suite"
  printf '  valid/\n'
  for f in "$valid_dir"/*.yaml; do
    [[ -e "$f" ]] || continue
    validate "$schema" "$f" valid || fails=$((fails + 1))
  done
  printf '  invalid/\n'
  for f in "$invalid_dir"/*.yaml; do
    [[ -e "$f" ]] || continue
    validate "$schema" "$f" invalid || fails=$((fails + 1))
  done
  return "$fails"
}

total_fails=0

run_suite fleet   "$schemas_dir/fleet.v1.schema.json"   || total_fails=$((total_fails + $?))
run_suite cluster "$schemas_dir/cluster.v1.schema.json" || total_fails=$((total_fails + $?))

printf '\n'
if [[ $total_fails -eq 0 ]]; then
  green "All schema fixtures passed."
  exit 0
fi
red "$total_fails fixture assertion(s) failed."
exit 1
