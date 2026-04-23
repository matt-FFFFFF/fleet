# modules/cluster-kv/terraform.tf
#
# Cluster-local Key Vault. Authored as azapi to stay on the fleet's
# chosen provider set (no azurerm here even though the root stage
# declares both — keeps the module provider-invariant with the rest
# of the bootstrap/stages family).

terraform {
  required_version = "~> 1.14"

  required_providers {
    azapi = {
      source  = "Azure/azapi"
      version = "~> 2.9"
    }
  }
}
