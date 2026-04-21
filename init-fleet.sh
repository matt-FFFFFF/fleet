#!/usr/bin/env bash
# init-fleet.sh — one-shot initializer for adopters of the fleet template repo.
#
# What it does, in order:
#   1. Preflight: checks for terraform + git; refuses to run if
#      .fleet-initialized already exists or the worktree is dirty (bypass
#      with --force).
#   2. Loads init/inputs.auto.tfvars and, for every variable whose value is
#      still the sentinel "__PROMPT__", prompts on the TTY and writes the
#      answer back into the file. Non-interactive callers pre-fill the
#      file (or pass --values-file to overlay) so no prompts fire.
#   3. Runs `terraform -chdir=init init && apply` — Terraform validates
#      inputs (regex-based validation blocks per variable) and renders:
#        clusters/_fleet.yaml
#        .github/CODEOWNERS
#        README.md
#        .fleet-initialized
#   4. Optionally removes the example clusters (interactive prompt; kept by
#      default in --non-interactive mode for CI convenience).
#   5. Self-cleanup: deletes init/, this script, the selftest workflow, and
#      the CI fixtures directory so the adopter repo contains zero template
#      machinery.
#
# Usage:
#   ./init-fleet.sh                                 # interactive wizard
#   ./init-fleet.sh --non-interactive               # CI; all values must be
#                                                    # pre-filled in init/inputs.auto.tfvars
#   ./init-fleet.sh --non-interactive --values-file <path>.tfvars
#                                                   # overlay values from another file
#   ./init-fleet.sh --force                         # allow dirty tree / re-init
#
# See docs/adoption.md.

set -euo pipefail

die()  { printf 'init-fleet: %s\n' "$*" >&2; exit 1; }
warn() { printf 'init-fleet: %s\n' "$*" >&2; }
info() { printf '  %s\n' "$*"; }

# ---- flag parsing -----------------------------------------------------------

FORCE=0
NON_INTERACTIVE=0
VALUES_FILE=""

while (($#)); do
  case "$1" in
    --force)            FORCE=1; shift ;;
    --non-interactive)  NON_INTERACTIVE=1; shift ;;
    --values-file)      VALUES_FILE="${2:?--values-file needs a path}"; shift 2 ;;
    --values-file=*)    VALUES_FILE="${1#*=}"; shift ;;
    -h|--help)
      sed -n '2,33p' "$0"; exit 0 ;;
    *) die "unknown flag: $1" ;;
  esac
done

# ---- preflight --------------------------------------------------------------

command -v terraform >/dev/null 2>&1 || die "terraform is required (~> 1.9)"
command -v git       >/dev/null 2>&1 || die "git is required"
# python3 is used for the --values-file overlay and __PROMPT__ substitution
# (see overlay_tfvar / prompt loops below). Enforced up-front so adopters
# without it fail fast with an actionable message rather than mid-run.
command -v python3   >/dev/null 2>&1 || die "python3 is required (used for tfvars in-place edits)"

repo_root="$(cd "$(dirname "$0")" && pwd)"
cd "$repo_root"

init_dir="$repo_root/init"
tfvars="$init_dir/inputs.auto.tfvars"
marker=".fleet-initialized"

[[ -d "$init_dir" ]] || die "init/ directory not found; is this a template repo checkout?"
[[ -f "$tfvars"   ]] || die "init/inputs.auto.tfvars not found"

if [[ -f "$marker" && $FORCE -eq 0 ]]; then
  die "$marker exists; this repo has already been initialized. Pass --force to re-init."
fi

if [[ $FORCE -eq 0 ]] && git rev-parse --git-dir >/dev/null 2>&1; then
  if ! git diff-index --quiet HEAD -- 2>/dev/null; then
    die "worktree is dirty; commit or stash first, or pass --force."
  fi
fi

if [[ -n "$VALUES_FILE" && ! -f "$VALUES_FILE" ]]; then
  die "values file not found: $VALUES_FILE"
fi

# ---- overlay --values-file (CI path) ----------------------------------------
#
# If the caller passed --values-file, replace inputs.auto.tfvars outright
# with the supplied file. The values file is expected to be a complete set
# of adopter inputs (matching the shape of inputs.auto.tfvars, including
# the `environments` map block); CI (.github/workflows/template-selftest.yaml)
# feeds .github/fixtures/adopter-test.tfvars this way to drive init
# non-interactively. This avoids having to parse HCL map/object literals
# in shell: the fixture already carries every top-level variable the
# module declares.

if [[ -n "$VALUES_FILE" ]]; then
  info "Overlaying values from $VALUES_FILE (replacing inputs.auto.tfvars)"
  cp "$VALUES_FILE" "$tfvars"
fi

# ---- prompt for __PROMPT__ sentinels ----------------------------------------
#
# Extract every `key = "__PROMPT__"` line from inputs.auto.tfvars and, unless
# --non-interactive was given, ask the user to fill it in. Hard errors if any
# sentinel remains after the pass — Terraform validation will catch malformed
# values (GUIDs, slugs, etc.), so the shell doesn't need to duplicate those
# regexes.

remaining_prompts() {
  # Prints each top-level (column-0) key that still equals "__PROMPT__".
  # Intentionally does NOT match indented assignments inside map/object
  # literals (e.g. `environments = { mgmt = { subscription_id = "__PROMPT__" } }`):
  # those are edited by the adopter directly before running init-fleet.sh.
  # See init/inputs.auto.tfvars for the `environments` map shape.
  grep -E '^[a-zA-Z_][a-zA-Z0-9_]*[[:space:]]*=[[:space:]]*"__PROMPT__"' "$tfvars" \
    | sed -E 's/^([a-zA-Z_][a-zA-Z0-9_]*)[[:space:]]*=.*$/\1/'
}

pending="$(remaining_prompts || true)"

if [[ -n "$pending" ]]; then
  if [[ $NON_INTERACTIVE -eq 1 ]]; then
    echo "init-fleet: --non-interactive but these variables are still __PROMPT__:" >&2
    printf '  %s\n' $pending >&2
    die "pre-fill them in init/inputs.auto.tfvars or pass --values-file"
  fi

  echo "Fleet adopter initialization. Ctrl-C to abort." >&2
  echo "" >&2
  for key in $pending; do
    # Pull the inline # comment from the tfvars line for use as the prompt.
    # Anchor at column 0 so we only inspect top-level assignments (map
    # interiors are intentionally excluded from the prompt flow).
    hint="$(grep -E "^${key}[[:space:]]*=" "$tfvars" \
            | awk -F'#' 'NF>1 { sub(/^[[:space:]]+/, "", $2); print $2; exit }' || true)"
    while true; do
      if [[ -n "$hint" ]]; then
        read -r -p "  ${key} (${hint}): " val </dev/tty
      else
        read -r -p "  ${key}: " val </dev/tty
      fi
      [[ -n "$val" ]] && break
      warn "  ✗ required"
    done
    # Escape backslashes and double-quotes for embedding in a tfvars string.
    esc="${val//\\/\\\\}"
    esc="${esc//\"/\\\"}"
    python3 - "$tfvars" "$key" "$esc" <<'PY'
import pathlib, re, sys
path, key, val = sys.argv[1], sys.argv[2], sys.argv[3]
p = pathlib.Path(path)
text = p.read_text()
# Anchor at start-of-line (column 0). Map-interior assignments are
# intentionally out of scope for the prompt flow — the shell does not
# traverse nested literals.
pattern = re.compile(rf'^{re.escape(key)}(\s*=\s*)"__PROMPT__"', re.MULTILINE)
replacement = rf'{key}\g<1>"{val}"'
new_text, n = pattern.subn(replacement, text)
assert n == 1, f"failed to substitute {key}"
p.write_text(new_text)
PY
  done
  echo "" >&2
fi

# Final sentinel sweep — should be empty now.
if [[ -n "$(remaining_prompts || true)" ]]; then
  die "internal error: __PROMPT__ sentinels remain after collection"
fi

# ---- terraform apply --------------------------------------------------------

# Stamp the template commit into the marker so adopters can trace their init
# back to a known template SHA.
template_commit="$(git -C "$repo_root" rev-parse HEAD 2>/dev/null || echo unknown)"

info "Running terraform init"
terraform -chdir="$init_dir" init -input=false -no-color >/dev/null

info "Running terraform apply"
terraform -chdir="$init_dir" apply \
  -input=false -no-color -auto-approve \
  -var "template_commit=${template_commit}"

# ---- optional: example cluster removal --------------------------------------

if [[ $NON_INTERACTIVE -eq 0 ]]; then
  read -r -p "Keep example clusters (aks-mgmt-01, aks-nonprod-01)? [Y/n] " keep_ans </dev/tty
  if [[ "$keep_ans" =~ ^[Nn]$ ]]; then
    info "Removing example clusters"
    rm -rf clusters/mgmt/eastus/aks-mgmt-01 clusters/nonprod/eastus/aks-nonprod-01
  fi
fi

# ---- self-cleanup -----------------------------------------------------------
#
# Everything below this point removes template-only machinery from the
# adopter's checkout. After this, the repo has no trace of init/, the
# selftest workflow, or this script — only the rendered artefacts and the
# marker remain.

info "Removing template scaffolding"
rm -rf "$init_dir"
rm -f "$repo_root/.github/workflows/template-selftest.yaml"
rm -f "$repo_root/.github/workflows/status-check.yaml"
rm -rf "$repo_root/.github/fixtures"
# The legacy sed-based template file, if still present from an earlier
# iteration of the template, is no longer needed.
rm -f "$repo_root/clusters/_fleet.yaml.template"

# Un-ignore Terraform lock files and `clusters/_fleet.yaml`. The
# template gitignores lock files to avoid churn from local/CI
# `terraform init` runs, and gitignores `_fleet.yaml` because it is a
# rendered byproduct in the template (never committed upstream).
# Adopter repos commit both for reproducibility / single-source-of-
# truth. Drop the lines if present.
if [ -f "$repo_root/.gitignore" ]; then
  # Portable temp file creation (GNU + BSD/macOS mktemp).
  if ! tmp=$(mktemp 2>/dev/null); then
    tmp=$(mktemp -t init-fleet.XXXXXX) || die "failed to create temporary file"
  fi
  # grep exits 0 (matches found) or 1 (no matches) — both mean the
  # output in $tmp is valid; only exit >=2 signals a real error that
  # must not clobber the original .gitignore.
  if grep -Ev '^(\*\*/\.terraform\.lock\.hcl|/clusters/_fleet\.yaml)$' "$repo_root/.gitignore" > "$tmp"; then
    mv "$tmp" "$repo_root/.gitignore"
  else
    grep_status=$?
    if [ "$grep_status" -eq 1 ]; then
      mv "$tmp" "$repo_root/.gitignore"
    else
      rm -f "$tmp"
      die "failed to update $repo_root/.gitignore"
    fi
  fi
fi

rm -f "$0"

echo ""
echo "✔ Initialization complete."
echo "  - Review changes: git status && git diff"
echo "  - Commit:         git add -A && git commit -m 'chore: initialize fleet from template'"
echo "  - Next:           docs/adoption.md → terraform/bootstrap/fleet"
