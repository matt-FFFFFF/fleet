variable "container_app_environment_id" {
  type        = string
  description = "The resource id of the Container App Environment."
}

variable "environment_variables" {
  type = set(object({
    name  = string
    value = string
  }))
  description = "List of environment variables to pass to the container."
}

variable "keda_meta_data" {
  type        = map(string)
  description = "The metadata for the KEDA scaler."
}

variable "keda_rule_type" {
  type        = string
  description = "The type of the KEDA rule."
}

variable "location" {
  type        = string
  description = "Azure region where the resource should be deployed."
  nullable    = false
}

variable "postfix" {
  type        = string
  description = "Postfix used for naming the resources where the name isn't supplied."

  validation {
    condition     = length(var.postfix) <= 20
    error_message = "Variable 'name' must be less than 20 characters due to container app job naming restrictions. '${var.postfix}' is ${length(var.postfix)} characters."
  }
}

variable "registry_login_server" {
  type        = string
  description = "The login server of the container registry."
}

variable "resource_group_id" {
  type        = string
  description = "The id of the resource group where the resources will be deployed."
}

variable "sensitive_environment_variables" {
  type = set(object({
    name                      = string
    value                     = string
    container_app_secret_name = string
    keda_auth_name            = optional(string)
  }))
  description = "List of sensitive environment variables to pass to the container."
  sensitive   = true
}

variable "user_assigned_managed_identity_id" {
  type        = string
  description = "The resource Id of the user assigned managed identity."
}

variable "environment_variables_placeholder" {
  type = set(object({
    name  = string
    value = string
  }))
  default     = []
  description = "List of environment variables to pass only to the placeholder container."
  nullable    = false
}

variable "managed_identity_auth_enabled" {
  type        = bool
  default     = false
  description = "Whether to use managed identity for KEDA authentication instead of PAT."
  nullable    = false
}

variable "registry_password" {
  type        = string
  default     = null
  description = "Password of the container registry."
  sensitive   = true
}

variable "registry_username" {
  type        = string
  default     = null
  description = "Name of the container registry."
}

variable "retry" {
  type = object({
    error_message_regex  = optional(list(string), ["ReferencedResourceNotProvisioned"])
    interval_seconds     = optional(number, 10)
    max_interval_seconds = optional(number, 180)
  })
  default     = {}
  description = "Retry configuration for the resource operations"
}

# -----------------------------------------------------------------------------
# Vendor extension (see ../../VENDORING.md): KV-reference mode for the
# GitHub App PEM secret.
#
# When `github_app_key_kv_secret_id` is non-null:
#   - The plaintext APP_PRIVATE_KEY value from `sensitive_environment_variables`
#     is ignored (it's expected to have been passed in as `value = null`).
#   - The `application-key` container secret is emitted in the Container App
#     Job body as a `keyVaultUrl` + `identity` reference, so the PEM never
#     lands in Terraform state.
#   - `github_app_key_identity_id` MUST be a UAMI id with `Key Vault Secrets
#     User` on the target secret; the UAMI must also be attached to the
#     Container App Jobs themselves (via `var.user_assigned_managed_identity_id`).
#
# Upstream tracking: <https://github.com/Azure/terraform-azurerm-avm-ptn-cicd-agents-and-runners/issues>
# Once `azurerm_container_app_job.secret.value_wo` lands in azurerm and the
# upstream module adopts it, this patch becomes redundant.
# -----------------------------------------------------------------------------

variable "github_app_key_kv_secret_id" {
  type        = string
  default     = null
  description = "(Optional.) Versionless Key Vault secret URI for the GitHub App PEM. When set, the `application-key` secret is emitted as a KV reference."
}

variable "github_app_key_identity_id" {
  type        = string
  default     = null
  description = "(Optional.) UAMI resource id used by the Container App to read `github_app_key_kv_secret_id`."

  validation {
    condition     = var.github_app_key_kv_secret_id == null || (var.github_app_key_identity_id != null && trimspace(coalesce(var.github_app_key_identity_id, " ")) != "")
    error_message = "github_app_key_identity_id is required (non-empty) when github_app_key_kv_secret_id is set."
  }
}
