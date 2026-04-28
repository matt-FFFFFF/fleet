# Findings

Open design/implementation concerns that don't fit `PLAN.md` (intent) or
`STATUS.md` (tracking index). Each finding is a detailed rationale for
work queued in the Rework program in `STATUS.md`. Close a finding by
deleting its section when the matching rework item is completed.

## F9 — Argo CD topology: every cluster reconciles its own slice; no cross-cluster reach

**Observation.** PLAN and supporting docs refer to a "top-level
app-of-apps" on the mgmt cluster without specifying what it owns,
what it reaches, or what credentials it holds. That framing
invites operators to grant mgmt Argo remote-cluster credentials
and build a centralised fleet reconciler — adding significant
identity/authorization machinery (UAMIs, FICs, AAD groups,
cross-cluster Secret writes, narrow ClusterRoles) for no
operational benefit over a pull-based topology, because all
policy artefacts already live in Git and every cluster already
runs a local Argo.

**Target design — pull-only; mgmt is not special.**

1. **Every cluster runs its own Argo**, installed by Stage 2.
   No structural distinction between mgmt and non-mgmt. Each
   Argo watches exactly one Git path:
   `clusters/<env>/<region>/<name>/`. No Argo anywhere holds
   credentials to any cluster other than itself.

2. **Per-cluster directory layout.** Under each cluster's
   slice, two subtrees with distinct governance:

   ```
   clusters/<env>/<region>/<name>/
     policy/
       appprojects/<team>.yaml           # generator output (F11)
       quotas/<team>.yaml                # generator output
       netpols/<name>.yaml               # generator output
       constraints/<name>.yaml           # generator output
     apps/
       <team>-<app>/…                    # team-authored or Kargo-committed
   ```

   The root `Application` Stage 2 writes on each cluster points
   at `clusters/<env>/<region>/<name>/` (the whole directory) and
   syncs both subtrees. Policy artefacts are applied before or
   alongside workloads on the same cluster, by the same
   reconciler, with no cross-cluster ordering dependency.

3. **Stage 2 bootstraps local Argo via Terraform.** Helm release
   of Argo with workload-identity wiring (KSA annotated with
   the cluster's own UAMI client-id, projected SA-token volume,
   `azure.workload.identity/use: "true"` labels). Stage 2 then
   writes the root `Application` CR and hands off. After Stage 2
   completes, Argo self-manages: the root Application syncs
   Argo's own config (`argocd-cm`, `argocd-rbac-cm`, HA replica
   counts, etc.) from Git. Subsequent Argo upgrades land via
   Git commits, not via re-running Stage 2.

4. **Repo access via the cluster's UAMI.** Argo reads the fleet
   repo authenticated as the cluster's own UAMI (federated to
   its KSA), not via a static GitHub token. The UAMI is granted
   read access on the fleet repo via the existing GitHub-App
   flow (`fleet-meta` posts a repo-scoped installation access
   token into the cluster's KV; ESO projects it into Argo's
   `argocd-repo-creds` secret). No long-lived PAT anywhere.

5. **Kargo is the sole fleet-wide coordinator.** Kargo runs on
   mgmt (its only cluster home — its state model requires a K8s
   API somewhere), watches the shared ACR via its Warehouse,
   and authors Git commits into
   `clusters/<env>/<region>/<name>/apps/`. Remote clusters'
   local Argos pick those commits up on their next sync.
   Cross-cluster coordination happens entirely through Git —
   the fleet repo is the message bus. Kargo has **no** reach to
   any cluster other than mgmt itself.

6. **AppProjects + team policy generated from Git artefacts.**
   See F11. Humans edit `teams/<team>.yaml`; a GH Actions
   generator renders per-cluster policy YAML into each target
   cluster's `policy/` subtree and commits back. Each cluster's
   local Argo picks up its own `policy/` tree on the next sync.
   No central push; no fleet-wide `argocd-rbac-cm` replication.

### Why pull-only, not push

The alternative considered and rejected: a "Tier 1" mgmt Argo
that reconciles policy objects (AppProjects, quotas, NetPols,
Gatekeeper constraints) onto every spoke via workload-identity
federation and a narrow ClusterRole. Superficially attractive —
single UI for fleet policy, automatic fan-out on new clusters —
but examined carefully, every purported advantage already holds
with pull-only:

- **Centralised reconciliation.** Every cluster's local Argo
  reconciles its own policy from Git. Drift detection, desired-
  vs-actual comparison, Argo UI visibility — all present per-
  cluster. Aggregated visibility across clusters is a dashboard
  concern, not a controller concern; you don't need a central
  reconciler to get central visibility.
- **Fan-out on new clusters.** When a new cluster is onboarded,
  Stage 2 installs its local Argo pointing at its own
  `clusters/<...>/` path. The generator has already emitted
  `clusters/<new>/policy/` into the fleet repo (F11). The new
  cluster starts syncing on first boot. No cluster-connection
  Secret on mgmt, no cross-cluster write, no mgmt-must-be-up
  dependency at onboarding time.
- **Policy uniformity.** The generator (F11) is what guarantees
  "edit `teams/foo.yaml` → consistent AppProjects across target
  clusters." A central reconciler would just move bits
  Git-to-cluster that the local Argo is already moving — an
  extra hop, not an extra guarantee.

Push-based centralisation would cost: a fleet-scoped UAMI
(`id-mgmt-argo-fleet-sync`), two FICs (controller + server), two
AAD groups (`fleet-argo-policy-syncers`, `fleet-spoke-registrars`),
an `AKS Cluster User Role` assignment on every spoke for the
fleet UAMI plus an assignment on mgmt for every env UAMI, a
narrow ClusterRole + binding on every spoke, a Role + binding
in mgmt's `argocd` namespace permitting spoke Stage 2 to write
cluster-connection Secrets, and a cross-cluster write step in
every spoke's Stage 2 apply. A significant object graph spanning
three control planes (Entra, each spoke's kube API, mgmt's kube
API) with non-trivial ordering constraints — all in service of
properties Git-based fan-out already provides.

The one real property push-based centralisation offers that
pull-only doesn't: defense-in-depth against compromise of a
spoke's local Argo. A central reconciler is a separate control
loop with a separate identity; it can re-assert policy over a
compromised local Argo's head. This is a legitimate but narrow
property. Local Argo runs on the cluster it syncs into; if it's
compromised, the attacker likely has node-level access to that
cluster anyway and can read secrets, exec into pods, etc.
directly — manipulating AppProjects is an afterthought.
Treating local Argo's integrity as a cluster-level trust
boundary (the same way kube-apiserver's integrity is trusted)
is consistent with how the rest of the system handles cluster
scope. Fleet-wide visibility of per-cluster Argo reconciliation
state (Argo UI federation or a dashboard aggregating Argo
metrics from all clusters) gives operators the observability
they need without requiring a central writer.

### Kargo, revisited

Kargo is the only component in the system that spans clusters,
and it does so by writing to **Git**, not by reaching into
remote cluster APIs. This is the architectural pattern the
whole fleet follows: cross-cluster coordination is always via
Git, never via direct API access. Pull-only Argo reinforces
this pattern. A "Tier 1" mgmt Argo with remote cluster
credentials would have been the one exception — and removing it
leaves the architecture self-consistent: **Git is the only
cross-cluster communication channel, for every component, in
every direction.**

### Consequences

a. **PLAN terminology cleanup.** Any mention of a "top-level
   app-of-apps" on mgmt is replaced with "mgmt cluster runs its
   own local Argo, structurally identical to every other
   cluster's Argo." PLAN §5 (and wherever else the term lands)
   must reflect this.

b. **Stage 2 gains Argo install; no cross-cluster writes.**
   Installing Argo + writing the root Application becomes a
   concrete Stage 2 deliverable on every cluster. Keep it
   small: Helm release with WIF wiring + one root `Application`
   CR apply. No cluster-connection Secret emitted anywhere; no
   AAD group membership writes; no cross-cluster kubeconfig
   handling.

c. **Stage 1 unchanged relative to Argo.** No new UAMIs, no
   new FICs, no fleet-argo-policy-syncers group, no cross-env
   role assignments on mgmt AKS. Stage 1's existing scope
   (per-cluster Azure resources, per-cluster Kargo FIC writes
   on mgmt only) stays as-is.

d. **F2 unchanged.** Every env UAMI still needs
   `Application.ReadWrite.OwnedBy` on the Argo AAD app so
   Stage 2 can write per-cluster FICs for OIDC login to Argo.
   Kargo FIC rotation still runs as `fleet-mgmt` on Stage 1
   mgmt. F2 is independent of F9.

e. **Drift control for AppProjects.** With N clusters each
   applying their own AppProjects from a generator's output,
   two safeguards prevent drift between what "the same team"
   means across clusters:
   - **Generator is single-source.** All per-cluster AppProject
     files for team T come from the same `teams/<team>.yaml`;
     per-cluster substitution is limited to fields that must
     differ (e.g. cluster-scoped `destinations`). Drift is
     structurally blocked at generation time.
   - **CI validator.** Pre-merge check asserts that for every
     team, the generated AppProjects across clusters are
     byte-identical in fields that are supposed to be cluster-
     agnostic (`sourceRepos`, `roles`). Cheap backup if the
     generator logic ever regresses. See F11.

f. **DR posture.** Every cluster's local Argo continues to sync
   from Git regardless of any other cluster's state. Mgmt
   offline affects only Kargo (promotion engine) and mgmt's own
   workloads; nonprod/prod reconciliation is unaffected. This
   is the strongest DR property the topology can offer.

g. **Observability.** Fleet-wide visibility is a separate
   concern, solved by one of: (i) Argo UI's built-in
   multi-cluster mode using read-only `cluster` Secrets on
   mgmt (credentials scoped to `get` on Argo CRDs only — a
   small, bounded read path worth pursuing later if the
   per-cluster UIs become unwieldy), (ii) an external
   dashboard aggregating Argo's Prometheus metrics from all
   clusters, or (iii) `kubectl` contexts across clusters. None
   of these require a write-capable central reconciler.

h. **Non-goals.**
   - Removing Kargo or changing its host cluster. Kargo stays
     on mgmt.
   - OIDC login federation to Argo (unchanged: Stage 0 creates
     the AAD app; Stage 2 writes per-cluster FICs).
   - ESO secret fan-out (unchanged).
   - A read-only mgmt Argo for observability. Potentially
     desirable later; not part of F9's bootstrap scope.
   - Answering "should we drop Kargo in favour of
     runners-author-PRs?" — separate, larger design question.

### Scope of rework

1. **`PLAN.md`** — rewrite any §5 / §10 / §16 passages that
   mention "app-of-apps" or imply mgmt Argo has fleet-wide
   reach. Add a short topology section stating the pull-only
   target design above.
2. **`terraform/stages/2-bootstrap/`** — add the Argo Helm
   install (with WIF wiring) + root-Application write on every
   cluster. The module already exists as a scaffold; this fills
   in its Argo responsibilities.
3. **Repo credential flow.** Wire the fleet-meta GitHub-App
   installation-token flow to land a `repo-creds` Secret in
   each cluster's Argo via ESO. Short finding worth writing
   up; placeholder for now — noted here so implementers don't
   default to a static PAT.
4. **Generator design** — tracked in F11.
5. **`docs/adoption.md`** — new section "Argo topology"
   explaining that every cluster runs its own local Argo, Git
   is the sole cross-cluster channel, and mgmt has no fleet-
   wide reconciliation role.

**Why now.** The prior PLAN language admitted either topology.
Pinning pull-only here prevents mgmt Argo from accreting remote-
cluster credentials as a "natural" extension later, keeps
Stage 2 simple (local-only operations), and preserves the
architectural invariant that Git is the only cross-cluster
channel.

**Risk.** Policy enforcement depends on each cluster's local
Argo doing its job. Accepted — local Argo is treated as a
cluster-level trust boundary, monitored through the Argo UI
(per-cluster today; federated via a future read-only
aggregator if needed). Compromise of a cluster's local Argo is
equivalent to compromise of the cluster itself; defending
against it with a central reconciler would recover nothing and
cost the object graph documented above.

## F11 — AppProject + policy generator: teams schema, CI mechanics, validator

Depends on F9 (establishes AppProjects-in-Git as the chosen
design). F11 specifies the input format, the generator's
execution model, and the guardrails that keep generator output
trustworthy.

**Observation.** F9 decided (Option A): humans edit
`teams/<team>.yaml`; a generator renders per-cluster policy
artefacts into `clusters/<env>/<region>/<name>/policy/` and
commits them back to the fleet repo; mgmt Argo fans them out.
The decision is recorded; the shape of every component is not.
Without a finding, implementers will pick an ad-hoc YAML schema
and an ad-hoc CI wiring, and the resulting system will be
difficult to evolve.

### Input: `teams/<team>.yaml`

Single file per team at the repo root. Minimum viable schema:

```yaml
# teams/payments.yaml
name: payments
display_name: "Payments Platform"
owners:
  - mawhi@example.com
  - teamlead@example.com
github_team: payments-platform              # optional; gates PR approvals

# Which clusters the team deploys to, and quota per cluster.
destinations:
  - cluster_selector: { env: prod }
    namespaces: [payments, payments-edge]
    resource_quota:
      cpu: "16"
      memory: 64Gi
      pods: "200"
      persistent_volume_claims: "50"
  - cluster_selector: { env: nonprod }
    namespaces: [payments, payments-edge, payments-dev]
    resource_quota:
      cpu: "8"
      memory: 32Gi
      pods: "100"
      persistent_volume_claims: "25"

# Which Git repos this team's Argo may sync from.
source_repos:
  - https://github.com/example/payments-gitops
  - https://github.com/example/payments-shared-config

# Which Kubernetes kinds the team may author. Default conservative.
allowed_kinds:
  namespaced:
    - "*/Deployment"
    - "*/StatefulSet"
    - "*/Service"
    - "*/ConfigMap"
    - "*/Ingress"
    - "networking.k8s.io/NetworkPolicy"
    - "external-secrets.io/ExternalSecret"
    - "cert-manager.io/Certificate"
  cluster_scoped: []                        # empty by default

# Sync windows (optional, per-cluster).
sync_windows:
  - cluster_selector: { env: prod }
    kind: allow
    schedule: "0 8 * * MON-FRI"
    duration: 10h
    time_zone: UTC
  # default deny outside windows for prod, inferred if any allow present
```

**Schema stability contract.** Adding fields is always
non-breaking. Removing or renaming a field bumps a
`schemaVersion` at the top of the file (not shown in minimum
schema to keep the typical case clean; added only when needed).
Migrations are generator concerns, not operator concerns.

**Cluster selector semantics.** `cluster_selector` matches
against `cluster.yaml` labels. `{ env: prod }` matches every
cluster whose `_fleet.yaml` env section is `prod`. Conjunctive
AND across keys; no OR or negation (keep selectors boring).
Explicit `cluster: nonprod/swedencentral/aks-nonprod-1` also
supported for surgical one-offs but discouraged.

### Output: `clusters/<env>/<region>/<name>/policy/`

For each team T and each cluster C matching T's destinations,
the generator emits:

```
clusters/<env>/<region>/<name>/policy/
  appprojects/<team>.yaml          # argoproj.io/v1alpha1 AppProject
  quotas/<team>.yaml               # v1 ResourceQuota, per namespace
  syncwindows/<team>.yaml          # if team has sync_windows for this cluster
```

Each file carries a generator header:

```yaml
# GENERATED BY .github/workflows/policy-generator.yaml
# SOURCE: teams/payments.yaml @ <commit-sha>
# DO NOT EDIT — changes will be overwritten on next generator run.
```

The header is how humans (and pre-commit hooks) detect
hand-edits; CI rejects any file with the header whose content
differs from the generator's output for the current team YAML.

### Generator execution model

**Trigger.** `.github/workflows/policy-generator.yaml`, on
push to `main` (or configurable default branch) touching
`teams/**` or `clusters/**/cluster.yaml`. Also a manual
`workflow_dispatch` for operator-driven regenerations after
schema changes.

**Identity.** Runs as `fleet-meta` (the UAMI that already has
repo-write rights via its GitHub App PEM). No new identity.

**Body.** One invocation of `generator/render.py` (say),
living in-repo, Python + `ruamel.yaml`. Reads all of
`teams/*.yaml` and every `clusters/**/cluster.yaml`; renders
the full desired state of `clusters/**/policy/` in a scratch
dir; diffs against the current tree; opens a PR (or commits
directly to `main` if fleet policy permits — operator choice)
with title `chore(policy): regenerate after teams/<team>.yaml`.

**Idempotency.** Running the generator twice without any input
change produces a no-op diff. Tested in CI as part of the
validator.

**Performance.** Full regeneration is O(teams × clusters).
Both are bounded (<100 teams, <20 clusters typical), so
<500ms wall-time. No incremental logic needed.

### Validator: CI guardrails

Three checks, all in `.github/workflows/policy-validate.yaml`,
running on every PR touching `teams/**`, `clusters/**`, or
`generator/**`:

1. **Freshness.** Re-run the generator in a scratch dir;
   assert `diff -r` against the committed `clusters/**/policy/`
   is empty. Catches "operator edited `teams/payments.yaml`
   but forgot to run the generator" and "operator hand-edited
   a generated file".
2. **Cross-cluster consistency.** For each team, compare the
   generated AppProjects across all target clusters. Assert
   byte-identical in fields that must be cluster-agnostic:
   `sourceRepos`, `roles`, `clusterResourceWhitelist`,
   `namespaceResourceWhitelist`. Fields allowed to vary per
   cluster: `destinations`, `syncWindows`. Catches generator
   bugs that introduce accidental per-cluster drift.
3. **Schema validation.** Every `teams/*.yaml` passes a
   JSON-schema check (schema lives in-repo, alongside
   generator). Every generated policy file passes OpenAPI
   validation against the target cluster's Argo/K8s types
   (via `kubeconform` with CRD schemas).

CI fails loudly on any check; generator PRs pass all three by
construction.

### Trust model

The generator is **code**, reviewable in PRs. The generator's
output is **data**, reviewable in PRs. Both pass through the
same PR-approval gate as any other repo change. An operator
compromising the generator can author arbitrary AppProjects,
but so can an operator compromising the fleet repo directly —
the generator does not widen the attack surface, and the
freshness validator catches unauthorized edits to generated
files that bypass the generator.

### Consequences

a. **Stage 2 root Application reference.** Tier 2 Argo's
   root Application on each cluster references AppProjects
   by name in its `project:` field. Those names come from
   `teams/<team>.yaml`. Stage 2 needs no generator awareness
   — it just applies the root Application and trusts Tier 1
   (mgmt Argo, per F9) to have installed the matching
   AppProjects before Tier 2 syncs.

b. **Race on first-ever cluster onboarding.** Tier 2 Argo
   comes up before Tier 1 has synced AppProjects to the new
   cluster. Team Applications on that cluster will fail
   closed with "AppProject <team> not found" until Tier 1
   catches up (sync cycle = minutes). Acceptable: a new
   cluster with no workloads is the expected state during
   onboarding; Tier 1 catches up well before any team
   deployment is attempted.

c. **Team offboarding.** Deleting `teams/<team>.yaml` causes
   the generator to remove all per-cluster AppProject files
   for that team. Mgmt Argo's ApplicationSet then prunes
   the AppProjects from spokes. Team workloads fail closed
   on next sync. Clean and audit-able.

d. **Schema evolution.** The schema is defined in-repo
   alongside the generator. Adding optional fields requires
   only a generator update. Adding required fields (rare,
   avoid) requires a migration pass over existing
   `teams/*.yaml` — committed as a separate PR whose diff is
   the migration itself.

### Non-goals

- Managing Kubernetes-native RBAC (`Role`, `RoleBinding`).
  AppProjects govern Argo's sync authority; Kube RBAC
  governs API server authority. The two serve different
  purposes; conflating them into one "teams" concept
  confuses the audit trail. Kube RBAC stays a Stage 2
  responsibility authored per-cluster; if an AppProject
  grants a team the ability to author `Role` objects in
  their namespace, that's the team's lever.
- Per-environment promotion of `teams/<team>.yaml`. The file
  is global — a team either exists in the fleet or doesn't.
  Per-cluster variation lives in `destinations[].cluster_selector`,
  not in separate per-env team files.
- Cross-fleet team sharing. Every fleet (adopter) owns its
  own `teams/`. A team shared across adopters is two
  separate definitions, kept in sync manually or via a
  shared-config mechanism outside this finding's scope.

### Scope of rework

1. **`generator/render.py`** + in-repo JSON schema for
   `teams/*.yaml`.
2. **`.github/workflows/policy-generator.yaml`** — trigger,
   identity, commit-back mechanics.
3. **`.github/workflows/policy-validate.yaml`** — freshness,
   cross-cluster consistency, schema validation.
4. **`teams/README.md`** — documents the schema and the
   operator workflow ("edit the file, merge the PR, wait
   for the generator bot to regenerate, merge that PR,
   wait for mgmt Argo to sync").
5. **`PLAN.md` §11 or §16** — one paragraph pointing at
   `teams/` as the fleet-operator-facing policy API.
6. **`docs/adoption.md`** — "Onboarding a team" section
   walking through the end-to-end flow.

**Why now.** Deferring the generator design until "after
infra stabilises" risks implementers wiring policy
per-cluster manually for the first few teams, then
discovering the schema they inferred is wrong once scale
demands it. Naming the schema now is cheap and sets the
expectation that `teams/` is the policy API from day one.

**Risk.** Schema lock-in. An early-adopter team's file format
becomes the de-facto contract; schema evolution requires
migration discipline. Mitigation: ship the schema with
`schemaVersion: 1` from the first commit, require all
additions to be optional, accumulate deprecations for a
bundled v2 migration rather than death-by-a-thousand-cuts.
