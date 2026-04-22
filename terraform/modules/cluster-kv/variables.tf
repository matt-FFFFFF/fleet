# modules/cluster-kv/variables.tf

variable "name" {
  description = "Key Vault name. Derived per docs/naming.md as `kv-<cluster.name>` (≤24 chars) unless the operator overrode `platform.keyvault.name`."
  type        = string
  nullable    = false

  validation {
    condition     = length(var.name) >= 3 && length(var.name) <= 24 && can(regex("^[a-zA-Z][a-zA-Z0-9-]{1,22}[a-zA-Z0-9]$", var.name))
    error_message = "Key Vault names must be 3-24 chars, start with a letter, contain only [a-zA-Z0-9-], and end with a letter or digit."
  }
}

variable "location" {
  description = "Azure region. Typically the cluster's region."
  type        = string
  nullable    = false
}

variable "parent_id" {
  description = "Resource group ARM id the KV is created under."
  type        = string
  nullable    = false
}

variable "tenant_id" {
  description = "AAD tenant id for the KV's access model."
  type        = string
  nullable    = false
}

variable "tags" {
  description = "Tags applied to the KV resource."
  type        = map(string)
  default     = {}
  nullable    = false
}
