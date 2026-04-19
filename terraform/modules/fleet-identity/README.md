# fleet-identity

Pure-function module that turns a parsed `clusters/_fleet.yaml` document
into the derived name set consumed by every bootstrap stage. No
providers; no resources; locals + outputs only.

The canonical derivation rules live in [`docs/naming.md`](../../../docs/naming.md)
and must agree with `terraform/config-loader/load.sh`. Both
`bootstrap/fleet` and `bootstrap/environment` call this module so the
rules are implemented exactly once.

## Usage

```hcl
locals {
  fleet_doc = yamldecode(file("${path.module}/../../../clusters/_fleet.yaml"))
}

module "identity" {
  source    = "../../modules/fleet-identity"
  fleet_doc = local.fleet_doc
}

resource "azapi_resource" "example" {
  name = module.identity.derived.state_storage_account
  # ...
}
```

## Testing

```
terraform -chdir=terraform/modules/fleet-identity init -test-directory=tests/unit
terraform -chdir=terraform/modules/fleet-identity test  -test-directory=tests/unit
```

Tests cover:
- Default derivations against the canonical selftest fixture.
- Override handling (`acr.name_override`, `keyvault.name_override`,
  `state.storage_account_name_override`).
- Truncation at Azure's 24-char Key Vault / Storage Account limit.
- `networking.*` try-paths returning null when the yaml lacks the
  section entirely.
