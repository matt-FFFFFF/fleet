# modules/aks-cluster/terraform.tf
#
# Provider set carveout (PLAN §2 documented deviation): the AVM AKS
# module declares `azurerm` (~> 4.46) and `random` (~> 3.5) as required
# providers. The managed cluster itself is azapi-authored, but the
# module ships `azurerm_management_lock`, `azurerm_role_assignment`,
# and `azurerm_monitor_diagnostic_setting` as optional features. We
# plan to use `diagnostic_settings` for AKS → Log Analytics wiring
# (and `role_assignments` for the RBAC phase), so propagating
# `azurerm` + `random` into the root stack is the intended path, not
# a workaround. Children of this module therefore also need the
# `azurerm` provider available from the caller.

terraform {
  required_version = "~> 1.14"

  required_providers {
    azapi = {
      source  = "Azure/azapi"
      version = "~> 2.9"
    }
    azurerm = {
      source  = "hashicorp/azurerm"
      version = "~> 4.46"
    }
    random = {
      source  = "hashicorp/random"
      version = "~> 3.5"
    }
  }
}
