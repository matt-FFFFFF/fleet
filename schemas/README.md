# schemas/

JSON Schema (Draft 2020-12) contracts for the YAML files this repo
consumes:

| File                                 | Schema                       |
|--------------------------------------|------------------------------|
| `clusters/_fleet.yaml`               | `fleet.v1.schema.json`       |
| `clusters/_defaults.yaml`            | `cluster.v1.schema.json`     |
| `clusters/<env>/_defaults.yaml`      | `cluster.v1.schema.json`     |
| `clusters/<env>/<region>/_defaults.yaml` | `cluster.v1.schema.json` |
| `clusters/<env>/<region>/<name>/cluster.yaml` | `cluster.v1.schema.json` |
| `clusters/_template/cluster.yaml`    | `cluster.v1.schema.json`     |

The schemas are the **structural** contract: shape, types, enum values,
the closed key-set on the per-region network block (the F19 mistake).
**Semantic** validation — "this AAD object id resolves", subnet-slot
uniqueness across an env-region, CIDR math, peering reachability — stays
in the bootstrap-stage HCL `precondition` blocks. The two layers
complement each other; the schema gives editors and pre-`terraform-init`
CI a fast structural check, and the HCL preconditions give
deploy-time safety against stale or unreachable cloud refs.

## Versioning

The version lives in the **filename** and the schema **`$id`**. There is
no `schema_version` field in the YAML files themselves. Editors pin to
a specific schema via the modeline at the top of each YAML:

```yaml
# yaml-language-server: $schema=/schemas/fleet.v1.schema.json
```

The path is workspace-root-relative so it resolves the same wherever
the file moves under `clusters/`.

### Bump policy

Stay on `vN`:

- Adding a new optional field.
- Relaxing a constraint (widening an enum, loosening a regex, adding a
  nullable variant).
- Fixing a schema bug to align it with reality (the schema was wrong;
  the consumer was always lenient).

Bump `vN` → `v(N+1)`:

- Renaming a field.
- Removing a field.
- Tightening a type (nullable → required, integer → small enum).
- Changing the meaning of an existing field.

Bumping is a single PR that:

1. Adds `schemas/<doc>.v(N+1).schema.json` alongside the old file.
2. Migrates every YAML file's modeline to the new path.
3. Updates fixtures under `schemas/tests/`.
4. Updates the parity surfaces named in `AGENTS.md` (`docs/naming.md`,
   `terraform/config-loader/load.sh`,
   `terraform/modules/fleet-identity/variables.tf`).
5. Retires the `vN` schema file when no consumer references it.

The previous schema file remains in-tree until the cut-over PR lands so
adopters mid-upgrade can validate against the version they were
authored against.

## Tests

`schemas/tests/test.sh` validates the curated fixtures under
`tests/fleet/{valid,invalid}/` and `tests/cluster/{valid,invalid}/`. It
asserts:

- every `valid/` fixture passes;
- every `invalid/` fixture fails (and prints the validator's error so
  schema regressions are obvious in CI logs).

The script is invoked locally and from the `schema-lint` CI job in
`.github/workflows/validate.yaml`.

## Parity surfaces

When you change a field that lives in `_fleet.yaml` or `cluster.yaml`,
move all four surfaces in the same PR:

1. `docs/naming.md` (derivation rules + length caps)
2. `terraform/config-loader/load.sh` (deep-merge + tfvars emission)
3. `terraform/modules/fleet-identity/variables.tf` (per-region key
   allow-list + the doc block describing the input shape)
4. `schemas/<doc>.vN.schema.json` (this directory)

`AGENTS.md` lists this rule under "Workflow rules".
