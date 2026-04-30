#!/usr/bin/env bash
# init-gh-apps.sh — provision the two GitHub Apps the fleet repo needs
# before `terraform/bootstrap/fleet` can apply (PLAN §16.4).
#
# Apps created (one per loop iteration):
#   - fleet-meta          admin-class App used by env/team-bootstrap workflows
#                          and by Stage 1 mgmt to publish mgmt-cluster repo vars
#   - fleet-runners       repo-scoped App used by KEDA to scale the self-hosted
#                          runner pool (actions:read + metadata:read)
#
# The GitHub API has no headless endpoint for App creation. Each App must be
# born through the App Manifest flow, which requires exactly one human click
# in the browser to consent to the permission set. This script automates
# everything around that click:
#
#   1. Build the manifest from clusters/_fleet.yaml.
#   2. Open a localhost listener on a random port (127.0.0.1 only, 5-min TTL).
#   3. Print + open(1) the manifest URL.
#   4. Capture the redirect with the temp code.
#   5. Exchange the code via `gh api .../conversions` for App credentials.
#   6. Guide installation of the App on the selected owner; record the
#      resulting installation id. (The operator chooses the repo selection
#      in the browser; the script does not verify repo inclusion.)
#   7. Persist credentials to ./.gh-apps.state.json (mode 0600, gitignored).
#
# After both Apps exist, the script:
#   - Writes terraform/bootstrap/fleet/.gh-apps.auto.tfvars (gitignored,
#     mode 0600) containing the four PEM-related variables
#     `bootstrap/fleet/variables.tf` declares: `fleet_runners_app_pem`,
#     `fleet_runners_app_pem_version`, `fleet_meta_app_pem`,
#     `fleet_meta_app_pem_version`. `*.auto.tfvars` auto-loads only
#     from the module root being applied, so dropping the file here lets
#     `terraform -chdir=terraform/bootstrap/fleet apply` pick the PEMs
#     up without an explicit `-var-file` flag and without "undeclared
#     variable" warnings. The `*_version` rotation tokens are opaque —
#     preserved across re-runs when the matching PEM is unchanged,
#     auto-bumped when the PEM in state differs from the PEM in the
#     existing tfvars (keeps `bootstrap/fleet`'s
#     `azapi_data_plane_resource` re-PUT behaviour aligned with actual
#     key rotations).
#   - Patches clusters/_fleet.yaml with `github_app.fleet_runners.{app_id,
#     installation_id}` AND `github_app.fleet_meta.{app_id,
#     installation_id}` so `bootstrap/fleet` apply just works. The
#     `fleet_meta` sub-block is inserted if absent (adopters initialized
#     before the template carried it).
#   - Self-deletes (only on a fully successful run).
#
# The full GitHub App payload (IDs, client IDs, client secrets, PEMs,
# webhook secrets, and other App metadata for all three Apps) is
# persisted in .gh-apps.state.json. Stage 0's eventual consumer
# (PLAN §16.4) will derive its own tfvars from state at that time; no
# Stage-0 tfvars file is emitted today.
#
# Idempotent: if .gh-apps.state.json already records all three Apps, the
# script re-emits the tfvars overlay + _fleet.yaml patch and exits 0
# without prompting. The tfvars file is overwritten in place on each run.
#
# NOTE ON RE-RUNS: by default this script self-deletes on a successful
# run (see --keep below). Adopters who expect to re-run it later — e.g.
# to rotate the `fleet-runners` App's private key via
# `gh api -X POST /apps/<slug>/keys` and regenerate the narrow tfvars
#     overlay — must either pass `--keep` on the initial run, or restore
#     the script from git history (`git show <template-commit>:init-gh-apps.sh`)
#     before re-running. The rotation-detection logic in the tfvars writer
#     assumes the script is available; it cannot run without it. The same
#     applies to rotating `fleet-meta`'s key.
#
# Usage:
#   ./init-gh-apps.sh              # interactive: opens browser, waits for clicks
#   ./init-gh-apps.sh --no-open    # don't shell out to open(1) — print URL only
#   ./init-gh-apps.sh --port N     # bind listener to a specific port
#   ./init-gh-apps.sh --keep       # don't self-delete on success — required
#                                    if you want to re-run later for key rotation
#
# Prereqs:
#   - clusters/_fleet.yaml exists (run ./init-fleet.sh first).
#   - `gh` CLI authenticated with `repo` + `admin:org` scopes
#     (e.g. `gh auth login --scopes 'repo,admin:org'`, or equivalent
#     $GH_TOKEN / $GITHUB_TOKEN env var).
#   - python3.
#
# See PLAN §16.4 and docs/adoption.md §4.

set -euo pipefail

die()  { printf 'init-gh-apps: %s\n' "$*" >&2; exit 1; }
warn() { printf 'init-gh-apps: %s\n' "$*" >&2; }
info() { printf '  %s\n' "$*"; }

# ---- flag parsing -----------------------------------------------------------

NO_OPEN=0
KEEP=0
PORT=0  # 0 == random

while (($#)); do
  case "$1" in
    --no-open) NO_OPEN=1; shift ;;
    --keep)    KEEP=1;    shift ;;
    --port)    PORT="${2:?--port needs a number}"; shift 2 ;;
    --port=*)  PORT="${1#*=}"; shift ;;
    -h|--help) sed -n '2,77p' "$0"; exit 0 ;;
    *) die "unknown flag: $1" ;;
  esac
done

# Validate --port up front: must be a non-negative integer in the TCP range.
# 0 is the sentinel for "pick a random port". Invalid input here would
# otherwise surface as a generic "listener failed to bind" error deep in
# the per-App flow.
if ! [[ "$PORT" =~ ^[0-9]+$ ]] || (( PORT > 65535 )); then
  die "--port must be an integer 0..65535 (0 == random); got: $PORT"
fi

# ---- preflight --------------------------------------------------------------

command -v python3 >/dev/null 2>&1 || die "python3 is required"
command -v gh      >/dev/null 2>&1 || die "gh CLI is required (https://cli.github.com)"

repo_root="$(cd "$(dirname "$0")" && pwd)"
cd "$repo_root"

fleet_yaml="$repo_root/clusters/_fleet.yaml"
state_file="$repo_root/.gh-apps.state.json"
# Narrow per-module overlay for `bootstrap/fleet`. Carries only the
# variables that module declares (fleet_runners_app_pem +
# fleet_runners_app_pem_version + fleet_meta_app_pem +
# fleet_meta_app_pem_version) so `terraform apply` auto-loads it
# without `-var-file` and without "undeclared variable" warnings.
# Stage 0's full-payload tfvars file is not emitted today; PLAN §16.4
# will derive it from state when the matching variable blocks land.
tfvars_file="$repo_root/terraform/bootstrap/fleet/.gh-apps.auto.tfvars"

[[ -f "$fleet_yaml" ]] || die "clusters/_fleet.yaml not found — run ./init-fleet.sh first"

# Auth: don't hard-require $GITHUB_TOKEN — `gh` resolves credentials from
# `gh auth login` (keyring), $GH_TOKEN, or $GITHUB_TOKEN in that order.
# Just verify that `gh api` actually works; the prereq scopes
# (repo + admin:org) are enforced by the first failing call, which
# is fine — we want to fail fast *here* on the smoke test, not mid-flow.
if ! gh api user -q .login >/dev/null 2>&1; then
  die "gh CLI cannot authenticate — run 'gh auth login --scopes repo,admin:org' or export GH_TOKEN / GITHUB_TOKEN (requires 'repo' + 'admin:org' scopes)"
fi

# ---- load _fleet.yaml -------------------------------------------------------
#
# We need: fleet.github_org, fleet.github_repo. Pure-python YAML extraction
# (no yq dependency); the values we need are top-level scalars in a known
# block, so a tiny parser via PyYAML is overkill — but PyYAML is in the
# Python stdlib? No. So we use a minimal regex extractor instead. This file
# is generated by init/, so its shape is stable.

read_yaml_scalar() {
  # Args: <yaml-file> <dotted-path>   e.g. fleet.github_org
  #
  # Minimal YAML key extractor sufficient for the well-known shape that
  # init/templates/_fleet.yaml.tftpl emits: every key is `<indent><name>:
  # <value>` with two-space nesting and no flow-style maps. Avoids a hard
  # dependency on yq.
  python3 - "$1" "$2" <<'PY'
import re, sys
path, dotted = sys.argv[1], sys.argv[2].split('.')
text = open(path).read()
indent = 0
remaining = text
for i, key in enumerate(dotted):
    # `[ \t]` instead of `\s` so the value match cannot eat the newline that
    # ends this key's line (which would silently jump into the next key).
    pat = re.compile(rf'^{" " * indent}{re.escape(key)}:[ \t]*(.*)$', re.MULTILINE)
    m = pat.search(remaining)
    if not m:
        sys.stderr.write(f"key not found: {'.'.join(dotted[:i+1])}\n"); sys.exit(2)
    if i == len(dotted) - 1:
        val = m.group(1).strip().strip('"').strip("'")
        val = re.sub(r'\s+#.*$', '', val)
        print(val)
        sys.exit(0)
    start = m.end()
    sub = remaining[start:]
    end_pat = re.compile(rf'^(?: {{0,{indent}}})\S', re.MULTILINE)
    em = end_pat.search(sub)
    remaining = sub[: em.start()] if em else sub
    indent += 2
PY
}

github_org=$(read_yaml_scalar "$fleet_yaml" fleet.github_org) \
  || die "failed to read fleet.github_org from $fleet_yaml"
github_repo=$(read_yaml_scalar "$fleet_yaml" fleet.github_repo) \
  || die "failed to read fleet.github_repo from $fleet_yaml"

[[ -n "$github_org"  ]] || die "fleet.github_org is empty in $fleet_yaml"
[[ -n "$github_repo" ]] || die "fleet.github_repo is empty in $fleet_yaml"

info "Target org/repo: $github_org/$github_repo"

# Determine if the fleet is owned by an org (vs a user); affects which
# manifest URL the operator is sent to and which install endpoint applies.
# Don't silently default on API failure — send a clear warning first.
if ! owner_type="$(gh api "users/$github_org" -q .type 2>/dev/null)"; then
  warn "failed to resolve owner type for '$github_org' via GitHub API — defaulting to Organization"
  owner_type="Organization"
fi
case "$owner_type" in
  Organization|User) : ;;
  *)
    warn "unexpected owner type '$owner_type' for '$github_org'; defaulting to Organization"
    owner_type="Organization"
    ;;
esac

# For user-owned fleets, `/user/installations` is scoped to the
# AUTHENTICATED user — not $github_org. If the caller is logged in as a
# different user, the installation lookup later will fail with an opaque
# "could not resolve installation id" error. Assert upfront for a clearer
# failure. (Best-effort: a PAT without the `read:user` scope may prevent
# `/user` from returning a login — in that case we skip the check and let
# the lookup surface its own error.)
if [[ "$owner_type" == "User" ]]; then
  if auth_login="$(gh api user -q .login 2>/dev/null)" && [[ -n "$auth_login" ]]; then
    if [[ "$auth_login" != "$github_org" ]]; then
      die "authenticated as '$auth_login' but fleet.github_org is '$github_org' (User-owned). For user-owned fleets you must be logged in as that user — run 'gh auth login' as '$github_org'."
    fi
  else
    warn "could not verify authenticated user matches '$github_org' (gh api user failed); continuing"
  fi
fi

# ---- state-file helpers -----------------------------------------------------

state_get() {
  # Args: <slug> <field>  ->  prints field or empty string
  [[ -f "$state_file" ]] || { echo ""; return 0; }
  python3 - "$state_file" "$1" "$2" <<'PY'
import json, sys
try:
    s = json.load(open(sys.argv[1]))
except Exception:
    print(""); sys.exit(0)
print((s.get(sys.argv[2], {}) or {}).get(sys.argv[3], "") or "")
PY
}

state_set() {
  # Args: <slug> <json-payload-as-string>
  python3 - "$state_file" "$1" "$2" <<'PY'
import json, os, sys
path, slug, payload = sys.argv[1], sys.argv[2], sys.argv[3]
try:
    s = json.load(open(path))
except Exception:
    s = {}
s[slug] = json.loads(payload)
# Mode 0600 — these are App secrets.
fd = os.open(path, os.O_WRONLY | os.O_CREAT | os.O_TRUNC, 0o600)
os.fchmod(fd, 0o600)  # tighten on pre-existing files; O_CREAT mode is ignored if file exists
with os.fdopen(fd, 'w') as f:
    json.dump(s, f, indent=2, sort_keys=True)
PY
}

# ---- App definitions --------------------------------------------------------
#
# Per-app metadata lives in two parallel arrays (slugs and permissions).
# Portable bash lacks ordered associative arrays, and the tfvars emitter
# in the main loop carries its own slug→prefix mapping, so we intentionally
# don't maintain a separate prefix array here.
# Permissions reference: https://docs.github.com/rest/apps/apps#permissions
#
# Permission keys MUST match the App Manifest schema exactly (singular,
# lowercase; values "read" or "write"). The repo-vs-org distinction is
# encoded by `default_repository_permissions: false` and the per-key
# placement in the manifest below.

apps_meta_perms='{"administration":"write","environments":"write","actions_variables":"write","secrets":"write","contents":"write"}'
# fleet-runners needs `administration:write` to mint repo-scoped runner
# registration tokens (POST /repos/{owner}/{repo}/actions/runners/registration-token).
# `actions:read` is for the KEDA scaler to enumerate queued workflow
# runs; `metadata:read` is the implicit minimum for any installed App.
apps_runners_perms='{"administration":"write","actions":"read","metadata":"read"}'

# fleet-meta writes to the repo; fleet-runners reads.
# Both are repo-scoped (no organization permissions requested).

APP_SLUGS=("fleet-meta" "fleet-runners")
APP_PERMS=("$apps_meta_perms" "$apps_runners_perms")

# ---- manifest flow per App --------------------------------------------------

create_app() {
  local slug="$1" perms="$2"
  local existing_id
  existing_id=$(state_get "$slug" "id")
  if [[ -n "$existing_id" ]]; then
    info "✓ $slug already in $state_file (id=$existing_id) — skipping"
    return 0
  fi

  info "Creating GitHub App: $slug"

  # Listener: random port if PORT==0; bind to 127.0.0.1 only; 5-minute timeout.
  # We launch the listener as a background python3 invocation that writes the
  # captured redirect query string to a temp file then exits.
  #
  # Cleanup strategy: avoid `trap ... RETURN` — RETURN traps set inside a
  # function interact unpredictably with `set -u` and with later function
  # invocations (see Copilot review feedback). Instead, define a local
  # cleanup closure, call it explicitly on the success path, and install a
  # narrowly-scoped EXIT trap that only runs if the script dies mid-function
  # (because `die` goes straight to `exit 1` without returning).
  local cb_file port_file conv_file="" listener_pid=""
  cb_file=$(mktemp -t gh-apps-cb.XXXXXX)
  port_file=$(mktemp -t gh-apps-port.XXXXXX)

  _create_app_cleanup() {
    [[ -n "${listener_pid:-}" ]] && kill "$listener_pid" 2>/dev/null || true
    rm -f "${cb_file:-}" "${port_file:-}" "${conv_file:-}"
    [[ -n "${form_dir:-}" ]] && rm -rf "$form_dir" || true
  }
  # Install as EXIT trap: only fires if we exit abnormally (die → exit 1).
  # The final explicit call at the bottom of this function clears it via
  # `trap - EXIT` before returning normally.
  trap _create_app_cleanup EXIT

  # Random nonce so we can verify the redirect is the one we initiated.
  local nonce
  nonce=$(python3 -c 'import secrets; print(secrets.token_urlsafe(16))')

  python3 - "$PORT" "$cb_file" "$port_file" "$nonce" <<'PY' &
import http.server, socket, sys, threading, time, urllib.parse

requested_port, cb_file, port_file, nonce = (
    int(sys.argv[1]), sys.argv[2], sys.argv[3], sys.argv[4]
)

class H(http.server.BaseHTTPRequestHandler):
    captured = False
    def log_message(self, *a, **kw): pass
    def do_GET(self):
        u = urllib.parse.urlparse(self.path)
        q = urllib.parse.parse_qs(u.query)
        if u.path != '/cb' or q.get('state', [''])[0] != nonce:
            self.send_response(400); self.end_headers()
            self.wfile.write(b"bad request"); return
        with open(cb_file, 'w') as f:
            f.write(q.get('code', [''])[0])
        self.send_response(200); self.end_headers()
        self.wfile.write(
            b"<html><body><h2>GitHub App created.</h2>"
            b"<p>You may close this tab and return to the terminal.</p>"
            b"</body></html>"
        )
        H.captured = True

srv = http.server.HTTPServer(('127.0.0.1', requested_port), H)
with open(port_file, 'w') as f:
    f.write(str(srv.server_address[1]))
# 5-minute timeout: poll handle_request with a deadline.
srv.timeout = 1
deadline = time.time() + 300
while not H.captured and time.time() < deadline:
    srv.handle_request()
sys.exit(0 if H.captured else 2)
PY
  listener_pid=$!

  # Wait for the listener to write its bound port.
  local waited=0 port=""
  while [[ -z "$port" && $waited -lt 50 ]]; do
    sleep 0.1
    [[ -s "$port_file" ]] && port=$(cat "$port_file")
    waited=$((waited + 1))
  done
  [[ -n "$port" ]] || die "listener failed to bind a port"

  # Build the manifest. The manifest shape is documented at
  # https://docs.github.com/apps/sharing-github-apps/registering-a-github-app-using-url-parameters
  local manifest_json
  manifest_json=$(python3 - "$slug" "$perms" "$port" <<'PY'
import json, sys
slug, perms_json, port = sys.argv[1], sys.argv[2], int(sys.argv[3])
manifest = {
    "name": slug,
    "url": f"http://127.0.0.1:{port}/cb",
    "redirect_url": f"http://127.0.0.1:{port}/cb",
    "public": False,
    "default_permissions": json.loads(perms_json),
    "default_events": [],
}
print(json.dumps(manifest))
PY
  )

  # The manifest URL is a GET to /settings/apps/new with the manifest as a
  # form value. GitHub renders a confirmation page; the operator clicks
  # "Create GitHub App" once, after which they are redirected to our listener.
  # We pre-build a tiny HTML form because the manifest payload exceeds query-
  # string limits.
  # mktemp portability: BSD (macOS) `mktemp -t` ignores an `.html` suffix
  # placed after the X's, while GNU mktemp accepts `XXXXXX.html`. To keep
  # a single temp artifact on both, use a tempdir and write a named file
  # inside it — cleanup nukes the whole dir.
  local form_dir=""
  form_dir=$(mktemp -d -t gh-apps-form.XXXXXX)
  local form_file="$form_dir/form.html"
  python3 - "$github_org" "$owner_type" "$nonce" "$manifest_json" "$form_file" <<'PY'
import html, json, sys
org, owner_type, nonce, manifest, out = sys.argv[1:6]
if owner_type == "Organization":
    action = f"https://github.com/organizations/{org}/settings/apps/new?state={nonce}"
else:
    action = f"https://github.com/settings/apps/new?state={nonce}"
with open(out, 'w') as f:
    f.write(
        "<!doctype html><html><body onload=\"document.forms[0].submit()\">"
        f"<form method='post' action='{html.escape(action)}'>"
        f"<input type='hidden' name='manifest' value='{html.escape(manifest)}'>"
        "<noscript><button type='submit'>Click to continue to GitHub</button></noscript>"
        "</form></body></html>"
    )
PY

  echo ""
  echo "  Open this file in a browser to create the '$slug' App:"
  echo "    file://$form_file"
  echo ""
  echo "  After clicking 'Create GitHub App', you'll be redirected to the"
  echo "  local listener at http://127.0.0.1:$port/cb (5-minute timeout)."
  echo ""

  if [[ $NO_OPEN -eq 0 ]] && [[ -t 1 ]] && command -v open >/dev/null 2>&1; then
    open "file://$form_file" || true
  elif [[ $NO_OPEN -eq 0 ]] && [[ -t 1 ]] && command -v xdg-open >/dev/null 2>&1; then
    xdg-open "file://$form_file" >/dev/null 2>&1 || true
  fi

  # Wait for the listener to capture the code. On timeout, `die` triggers
  # the EXIT trap which runs _create_app_cleanup.
  if ! wait "$listener_pid"; then
    die "listener timed out waiting for the redirect — re-run when ready"
  fi

  local code
  code=$(cat "$cb_file")
  [[ -n "$code" ]] || die "listener returned an empty code"

  # Exchange code for App credentials. Single-use, ~10 minute TTL.
  info "Exchanging temp code for App credentials"
  local conv_json
  if ! conv_json=$(gh api -X POST "/app-manifests/$code/conversions" 2>&1); then
    die "manifest exchange failed: $conv_json"
  fi

  # Persist credentials to state immediately — the API returns them once.
  # Write the raw JSON to a temp file and pass its path as argv[1]; we can't
  # pipe it on stdin because `python3 - <<'PY'` already consumes stdin to
  # read the script body, and we can't interpolate it into a `'''...'''`
  # literal because Python would interpret its `\n` escapes (notably inside
  # `pem`) as real newlines before json.loads sees them.
  # `conv_file` was declared at the top of the function and is cleaned up
  # by `_create_app_cleanup` — no RETURN trap here (RETURN traps leak out
  # of the function scope in bash; see the cleanup-strategy comment above).
  local payload
  conv_file=$(mktemp -t gh-apps-conv.XXXXXX)
  printf '%s' "$conv_json" >"$conv_file"
  payload=$(python3 - "$conv_file" <<'PY'
import json, sys
with open(sys.argv[1]) as f:
    c = json.load(f)
out = {
    "id": c.get("id"),
    "slug": c.get("slug"),
    "name": c.get("name"),
    "client_id": c.get("client_id"),
    "client_secret": c.get("client_secret"),
    "pem": c.get("pem"),
    "webhook_secret": c.get("webhook_secret"),
    "html_url": c.get("html_url"),
}
print(json.dumps(out))
PY
)
  state_set "$slug" "$payload"
  info "✓ $slug created and saved to .gh-apps.state.json"

  # Normal-path cleanup: remove temp files and clear the EXIT trap so it
  # doesn't fire on the next function's scope.
  _create_app_cleanup
  trap - EXIT
}

install_app() {
  local slug="$1"
  local app_slug app_id existing_install
  app_slug=$(state_get "$slug" "slug")
  app_id=$(state_get "$slug" "id")
  [[ -n "$app_id" ]] || die "internal: no id recorded for $slug"

  # Check whether we've already recorded an installation id for this App.
  # Note: installation_id is owner-scoped; it does not by itself guarantee
  # that $github_org/$github_repo is included in the install's repo
  # selection (which the operator can change at any time via the Apps UI).
  # The subsequent bootstrap/Stage-0 apply will surface any access gap.
  existing_install=$(state_get "$slug" "installation_id")
  if [[ -n "$existing_install" ]]; then
    info "✓ $slug installation already recorded (id=$existing_install)"
    return 0
  fi

  info "Locating installation of $app_slug (app_id=$app_id) on $github_org"

  # Find the installation_id for THIS specific App on the fleet org/user.
  # The obvious-looking `repos/<org>/<repo>/installation` endpoint requires
  # App-JWT auth (not a PAT) and returns 404 with PAT auth. Instead, list
  # all App installations on the owner scope and filter by app_id:
  #   - Organization: GET /orgs/{org}/installations    (admin:org PAT scope)
  #   - User:         GET /user/installations          (authenticated user;
  #     `/users/{user}/installations` is not a real route). For the user
  #     case, the authenticated caller must BE the user that owns the repo.
  #
  # Surface any API error (auth, missing scope, transient network) with a
  # clear message — `gh api` failures here are otherwise trapped silently
  # by the command substitution under `set -euo pipefail`.
  lookup_install_id() {
    local base result
    if [[ "$owner_type" == "Organization" ]]; then
      base="/orgs/$github_org/installations"
    else
      base="/user/installations"
    fi
    if ! result=$(gh api --paginate "$base" \
      --jq ".installations[]? // .[] | select(.app_id==$app_id) | .id" 2>&1); then
      die "failed to query GitHub App installations via 'gh api $base': $result. For org installs the caller must be an org admin and the token must include 'admin:org'."
    fi
    printf '%s\n' "$result" | head -n1
  }

  local install_id
  install_id=$(lookup_install_id)

  if [[ -z "$install_id" ]]; then
    # Not installed yet. Direct the operator to install it.
    local install_url="https://github.com/apps/$app_slug/installations/new"
    echo ""
    echo "  Install '$app_slug' on $github_org/$github_repo:"
    echo "    $install_url"
    echo ""
    if [[ $NO_OPEN -eq 0 ]] && [[ -t 1 ]]; then
      if command -v open >/dev/null 2>&1; then open "$install_url" || true
      elif command -v xdg-open >/dev/null 2>&1; then xdg-open "$install_url" >/dev/null 2>&1 || true
      fi
    fi
    read -r -p "  Press Enter once you've completed the install... " _ </dev/tty || true
    install_id=$(lookup_install_id)
  fi

  [[ -n "$install_id" ]] \
    || die "could not resolve installation id for $app_slug (app_id=$app_id) on $github_org"

  # Patch state file with installation_id.
  python3 - "$state_file" "$slug" "$install_id" <<'PY'
import json, os, sys
path, slug, iid = sys.argv[1], sys.argv[2], sys.argv[3]
s = json.load(open(path))
s[slug]["installation_id"] = int(iid)
fd = os.open(path, os.O_WRONLY | os.O_CREAT | os.O_TRUNC, 0o600)
os.fchmod(fd, 0o600)  # tighten on pre-existing files; O_CREAT mode is ignored if file exists
with os.fdopen(fd, 'w') as f:
    json.dump(s, f, indent=2, sort_keys=True)
PY
  info "✓ $slug installed (installation_id=$install_id)"
}

# ---- main loop --------------------------------------------------------------

for i in "${!APP_SLUGS[@]}"; do
  create_app "${APP_SLUGS[$i]}" "${APP_PERMS[$i]}"
  install_app "${APP_SLUGS[$i]}"
done

# ---- emit narrow bootstrap/fleet tfvars overlay -----------------------------
#
# `bootstrap/fleet/variables.tf` declares exactly two of the GH-App-derived
# variables: `fleet_runners_app_pem` (ephemeral/sensitive/nullable=false)
# and `fleet_runners_app_pem_version` (default "0"). The file is dropped at
# the module root so `terraform -chdir=terraform/bootstrap/fleet apply`
# auto-loads it without an explicit `-var-file` flag and without
# "undeclared variable" warnings.
#
# Stage 0's eventual full-payload tfvars (PLAN §16.4) is intentionally not
# emitted today — Stage 0 has no matching `variable` blocks declared, and
# any file shape we picked now would need revisiting once §16.4 lands.
# The full payload (IDs / client IDs / PEMs / webhook secrets for all three
# Apps) lives in .gh-apps.state.json; §16.4 will derive its own tfvars
# from state at that time.
#
# `fleet_runners_app_pem_version` is an opaque rotation token. On first
# emit it is `"0"`. On re-runs the writer reads the existing narrow
# tfvars file (if present), compares the PEM it carries against the
# PEM in `.gh-apps.state.json`, and:
#   - if the PEMs match → preserves the existing version verbatim
#     (so `terraform apply` is a no-op on the KV secret),
#   - if the PEMs differ → increments the version by 1 (treating it
#     as a decimal integer; non-integer values fall back to "1").
# This keeps `bootstrap/fleet`'s `azapi_data_plane_resource` change
# detection (which keys off `sensitive_body_version`) in sync with
# actual PEM rotations, even when the operator rotates the App's
# private key via `gh api -X POST /apps/<slug>/keys` and re-runs.

info "Writing $tfvars_file"
mkdir -p "$(dirname "$tfvars_file")"
python3 - "$state_file" "$tfvars_file" <<'PY'
import json, os, re, sys
state_path, out_path = sys.argv[1], sys.argv[2]
s = json.load(open(state_path))

# PEMs for both Apps that bootstrap/fleet seeds into the KV.
runners_pem = s["fleet-runners"]["pem"].rstrip("\n")
meta_pem    = s["fleet-meta"]["pem"].rstrip("\n")

# Read prior narrow tfvars (if any) to decide whether to bump each
# opaque rotation token. Parsing is surgical — we look for the named
# fields via regex. Treat a missing/malformed `*_version` as "0" for
# bump purposes so that a subsequent PEM rotation still increments
# the token to "1" (rather than resetting to first-emit semantics,
# which would leave `sensitive_body_version` unchanged and skip the
# KV re-PUT). If the matching `*_pem` block is absent we genuinely
# have no prior state and fall back to first-emit ("0").
def read_prior(path):
    try:
        with open(path) as f:
            text = f.read()
    except FileNotFoundError:
        return {}
    out = {}
    for key in ("fleet_runners_app_pem", "fleet_meta_app_pem"):
        m = re.search(rf'{key}\s*=\s*<<EOT\n(.*?)\nEOT', text, re.DOTALL)
        if m:
            out[key] = m.group(1).rstrip("\n")
    for key in ("fleet_runners_app_pem_version", "fleet_meta_app_pem_version"):
        m = re.search(rf'{key}\s*=\s*"([^"]*)"', text)
        if m:
            out[key] = m.group(1)
    return out

prior = read_prior(out_path)

def next_version(pem_key, ver_key, current_pem):
    prior_pem = prior.get(pem_key)
    prior_ver = prior.get(ver_key)
    if prior_pem is None:
        return "0"
    if prior_pem == current_pem:
        return prior_ver if prior_ver is not None else "0"
    base = prior_ver if prior_ver is not None else "0"
    try:
        return str(int(base) + 1)
    except ValueError:
        return "1"

runners_version = next_version(
    "fleet_runners_app_pem", "fleet_runners_app_pem_version", runners_pem,
)
meta_version = next_version(
    "fleet_meta_app_pem", "fleet_meta_app_pem_version", meta_pem,
)

lines = [
    "# Generated by ./init-gh-apps.sh — do not edit by hand.",
    "# Auto-loaded by `terraform -chdir=terraform/bootstrap/fleet apply`.",
    "# Gitignored (see .gitignore).",
    "#",
    "# *_app_pem_version is bumped automatically by the script when the",
    "# corresponding PEM in .gh-apps.state.json changes; bump manually if",
    "# you need to force a re-PUT of the KV secret.",
    "",
    "fleet_runners_app_pem         = <<EOT",
    runners_pem,
    "EOT",
    f'fleet_runners_app_pem_version = "{runners_version}"',
    "",
    "fleet_meta_app_pem            = <<EOT",
    meta_pem,
    "EOT",
    f'fleet_meta_app_pem_version    = "{meta_version}"',
    "",
]

fd = os.open(out_path, os.O_WRONLY | os.O_CREAT | os.O_TRUNC, 0o600)
os.fchmod(fd, 0o600)
with os.fdopen(fd, 'w') as f:
    f.write("\n".join(lines))
PY

# ---- patch _fleet.yaml: github_app.fleet_runners.{app_id, installation_id} ---
#
# bootstrap/fleet's runner module validates these are non-empty before apply
# (see terraform/bootstrap/fleet/main.runner.tf). The script is the only
# place that knows the values, so we write them back into the YAML.
# Surgical line-level edit (no YAML reformat); the keys are stable because
# init/templates/_fleet.yaml.tftpl emits them with two-space indent.

info "Patching $fleet_yaml with fleet-runners + fleet-meta IDs"
python3 - "$fleet_yaml" "$state_file" <<'PY'
import json, pathlib, re, sys
yaml_path, state_path = sys.argv[1], sys.argv[2]
state = json.load(open(state_path))

p = pathlib.Path(yaml_path)
text = p.read_text()

def find_block(text, parent, child):
    """Return (start, end) of the `parent: / <indent>child:` sub-block,
    or (None, None) if `parent.child` is absent.

    `start` is the column-0 offset of the line containing
    `<indent>child:`; `end` is the offset of the first line at depth
    `<= len(indent)` after that (i.e. where the sub-block ends).

    The `child:` header line may carry a trailing comment
    (`child: # explanation`) — `init/templates/_fleet.yaml.tftpl` emits
    them on the runners/meta sub-block headers — so the match accepts
    optional `[ \t]*(#.*)?` after the colon. The strict `\s*$` form
    would silently miss those headers and force the insert path even
    when the block already exists.
    """
    pat = re.compile(rf'^{re.escape(parent)}:[ \t]*(?:#.*)?$', re.MULTILINE)
    m = pat.search(text)
    if not m:
        return None, None
    after = m.end()
    child_pat = re.compile(
        rf'^(\s+){re.escape(child)}:[ \t]*(?:#.*)?$', re.MULTILINE,
    )
    cm = child_pat.search(text, after)
    if not cm:
        return None, None
    indent = cm.group(1)
    block_start = cm.start()
    end_pat = re.compile(rf'^(?: {{0,{len(indent) - 1}}})\S', re.MULTILINE)
    em = end_pat.search(text, cm.end())
    block_end = em.start() if em else len(text)
    return block_start, block_end

def replace_in_range(text, start, end, key, value):
    """Replace `key:` line within text[start:end]. Errors if absent."""
    region = text[start:end]
    pat = re.compile(
        rf'^(\s+){re.escape(key)}:\s*(?:"[^"]*"|[^\s#]+)(\s*(?:#.*)?)$',
        re.MULTILINE,
    )
    new_region, n = pat.subn(rf'\g<1>{key}: "{value}"\g<2>', region, count=1)
    if n == 0:
        raise SystemExit(
            f"init-gh-apps: could not find '{key}' in github_app sub-block "
            f"of {yaml_path} (range {start}..{end}); template may have drifted"
        )
    return text[:start] + new_region + text[end:]

def insert_block(text, parent, lines):
    """Append `lines` (already indented) inside the `parent:` block,
    at the end of its existing children."""
    pat = re.compile(rf'^{re.escape(parent)}:[ \t]*(?:#.*)?$', re.MULTILINE)
    m = pat.search(text)
    if not m:
        raise SystemExit(
            f"init-gh-apps: top-level key '{parent}:' missing from "
            f"{yaml_path}; cannot patch"
        )
    # Find first child indent.
    child_pat = re.compile(r'^(\s+)\S', re.MULTILINE)
    cm = child_pat.search(text, m.end())
    if not cm:
        raise SystemExit(
            f"init-gh-apps: '{parent}:' has no children in {yaml_path}; "
            "expected at least `fleet_runners:`"
        )
    # Find end of the parent block (first line at depth 0 after m.end()).
    end_pat = re.compile(r'^\S', re.MULTILINE)
    em = end_pat.search(text, cm.end())
    insert_at = em.start() if em else len(text)
    # Ensure trailing newline before insertion point.
    block = "\n".join(lines) + "\n"
    return text[:insert_at] + block + text[insert_at:]

def patch_app(text, state_key, yaml_app_key, extra_keys=()):
    app = state[state_key]
    app_id = str(app["id"])
    inst_id = str(app["installation_id"])
    extras = {k: str(app[k]) for k in extra_keys if app.get(k) is not None}
    start, end = find_block(text, "github_app", yaml_app_key)
    if start is None:
        # Block missing — adopter initialized before this template was
        # extended. Insert a fresh sub-block at the end of `github_app:`.
        # Indent must match the existing `fleet_runners:` block.
        existing_start, _ = find_block(text, "github_app", "fleet_runners")
        if existing_start is None:
            raise SystemExit(
                f"init-gh-apps: github_app.fleet_runners missing from "
                f"{yaml_path}; cannot infer indent"
            )
        line_start = text.rfind("\n", 0, existing_start) + 1
        indent = text[line_start:existing_start]
        lines = [
            f"{indent}{yaml_app_key}:",
            f'{indent}  app_id: "{app_id}"',
        ]
        for k, v in extras.items():
            lines.append(f'{indent}  {k}: "{v}"')
        lines.extend([
            f'{indent}  installation_id: "{inst_id}"',
            f'{indent}  private_key_kv_secret: {yaml_app_key.replace("_", "-")}-app-pem',
        ])
        return insert_block(text, "github_app", lines)
    text = replace_in_range(text, start, end, "app_id", app_id)
    for k, v in extras.items():
        # Re-locate end after each replace (length may have changed)
        # AND fall back to insertion when the key is missing entirely
        # — adopter initialized before the template carried this field
        # but already has the parent block (so `find_block` returned
        # non-None and we skipped the insert path above).
        s2, e2 = find_block(text, "github_app", yaml_app_key)
        region = text[s2:e2]
        kpat = re.compile(
            rf'^(\s+){re.escape(k)}:\s*(?:"[^"]*"|[^\s#]+)(\s*(?:#.*)?)$',
            re.MULTILINE,
        )
        if kpat.search(region):
            text = replace_in_range(text, s2, e2, k, v)
        else:
            # Insert `<indent>  k: "v"` immediately after the `<key>:`
            # header line within the sub-block. Indent picked from the
            # first existing child key.
            child_pat = re.compile(r'^(\s+)\S', re.MULTILINE)
            cm2 = child_pat.search(region)
            child_indent = cm2.group(1) if cm2 else "    "
            insertion = f'{child_indent}{k}: "{v}"\n'
            # Insert just after the `yaml_app_key:` header line.
            header_pat = re.compile(rf'^(\s+){re.escape(yaml_app_key)}:\s*$\n', re.MULTILINE)
            hm = header_pat.search(text, s2, e2)
            if not hm:
                raise SystemExit(
                    f"init-gh-apps: could not locate '{yaml_app_key}:' header "
                    f"to insert '{k}'"
                )
            text = text[:hm.end()] + insertion + text[hm.end():]
    s2, e2 = find_block(text, "github_app", yaml_app_key)
    return replace_in_range(text, s2, e2, "installation_id", inst_id)

text = patch_app(text, "fleet-runners", "fleet_runners")
text = patch_app(text, "fleet-meta",    "fleet_meta", extra_keys=("client_id",))

p.write_text(text)
PY

# ---- self-cleanup -----------------------------------------------------------

echo ""
echo "✔ All three GitHub Apps created, installed, and recorded."
echo "  - State:   $state_file (mode 0600, gitignored)"
echo "  - Tfvars:  $tfvars_file (mode 0600, gitignored)"
echo "  - YAML:    $fleet_yaml patched with fleet-runners IDs"
echo ""
echo "  Next:"
echo "    1. Commit the _fleet.yaml change."
echo "    2. Run terraform -chdir=terraform/bootstrap/fleet apply."
echo ""
echo "  Keep $state_file and $tfvars_file as long as you may need"
echo "  to re-plan or re-apply terraform/bootstrap/fleet — the"
echo "  fleet_{runners,meta}_app_pem variables are ephemeral/sensitive"
echo "  and cannot be read back from Terraform state or from the KV"
echo "  secret (bootstrap/fleet writes them via the KV data plane as"
echo "  write-only sensitive_body, so any future plan needs the PEMs"
echo "  supplied again). If you delete the tfvars file, you must"
echo "  supply both PEMs on each subsequent apply — e.g."
echo "      export TF_VAR_fleet_runners_app_pem=\"\$(jq -r .\\\"fleet-runners\\\".pem $state_file)\""
echo "      export TF_VAR_fleet_meta_app_pem=\"\$(jq -r .\\\"fleet-meta\\\".pem $state_file)\""
echo "  from a kept copy of $state_file, or fetch the PEMs from"
echo "  wherever you safely stashed them (a password manager, etc.)."
echo ""
if [[ $KEEP -eq 0 ]]; then
  echo "  This script will self-delete on exit. If you need to re-run it"
  echo "  later (e.g. to rotate the fleet-runners PEM), restore it from git"
  echo "  history first — or re-run with --keep next time to avoid the"
  echo "  restore step."
  echo ""
fi

if [[ $KEEP -eq 0 ]]; then
  # Best-effort self-delete. If the script can't remove itself (read-only
  # checkout, restricted perms, adopter has it open in an editor, etc.)
  # the provisioning work is still complete — don't surface a failure.
  rm -f "$0" 2>/dev/null || warn "could not remove $0; delete manually when convenient"
fi
