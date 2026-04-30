# Findings

Open design/implementation concerns that don't fit `PLAN.md` (intent) or
`STATUS.md` (tracking index). Each finding is a detailed rationale for
work queued in the Rework program in `STATUS.md`. Close a finding by
deleting its section when the matching rework item is completed.

## F26 — Runner-pool ACR name is a template-wide literal (`acrfleetrunners`)

**Observation.** `terraform/bootstrap/fleet/main.runner.tf` invokes the
vendored `cicd-runners` module without passing
`container_registry_name`. The module's `locals.tf` falls back to
`acr${var.postfix}` where the call site sets `postfix = "fleet-runners"`,
yielding the literal string `acrfleetrunners` (hyphens stripped per
the module's `replace(..., "-", "")`). Container Registry names are
Azure-globally-unique (`Microsoft.ContainerRegistry/registries`,
scope = global per [resource-name-rules](https://learn.microsoft.com/azure/azure-resource-manager/management/resource-name-rules#microsoftcontainerregistry)).

**Risk.** Every adopter using this template gets the same registry
name. The first one to apply wins; everyone else gets
`RegistryNameAlreadyExists` from ARM with no obvious adopter-side
remediation — `_fleet.yaml` carries no override field for this
registry, and the bootstrap module doesn't expose one.

**Fix.** One-line change at the call site: pass
`container_registry_name = "acr${local.fleet.name}runners"` (or a
similar fleet-name-bearing formula matching the docs/naming.md row
"Runner ACR (per-pool)"). The naming.md row already documents
`acrfleetrunners` as the current behaviour; that documentation is
the symptom — both the row and the call site need updating to a
formula keyed off `fleet.name`. Any adopter who has already applied
with the literal name will need to re-apply after the formula change
to land the new registry name (or the change ships behind an explicit
fleet-name interpolation that produces `acrfleetrunners` for their
specific fleet, accepting the collision they already hit).

If a particular `fleet.name` produces a name that's already taken
globally, the standard escape hatch (see docs/adoption.md §3
"Handling globally-unique-name collisions") applies — but the
`cicd-runners` module doesn't currently expose its
`container_registry_name` as an override field in `_fleet.yaml`.
Surfacing one (e.g. `runner_pool.container_registry_name_override`)
is a follow-up: low priority since adopters can edit the call site
in their fork if needed, and the template is pre-1.0.
