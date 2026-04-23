# Naming-parity harness.
#
# Drives `terraform/modules/fleet-identity/` from the committed (or
# template-rendered) `clusters/_fleet.yaml`. Emits `derived` +
# `networking_derived` as JSON so `check-naming-parity.sh` can diff
# against `config-loader/load.sh`'s output. Per AGENTS.md rule 5, any
# divergence is a contract violation and must fail CI.
#
# Pure-HCL module — no providers, no apply side effects. Run as:
#
#   terraform -chdir=.github/scripts/naming-parity init -backend=false
#   terraform -chdir=.github/scripts/naming-parity apply -auto-approve \
#     -var=fleet_yaml_path=$PWD/clusters/_fleet.yaml
#   terraform -chdir=.github/scripts/naming-parity output -json

terraform {
  required_version = "~> 1.14"
}

variable "fleet_yaml_path" {
  description = "Absolute path to clusters/_fleet.yaml (committed or template-rendered)."
  type        = string
}

module "fleet_identity" {
  source    = "../../../terraform/modules/fleet-identity"
  fleet_doc = yamldecode(file(var.fleet_yaml_path))
}

output "derived" {
  value = module.fleet_identity.derived
}

output "networking_derived" {
  value = module.fleet_identity.networking_derived
}
