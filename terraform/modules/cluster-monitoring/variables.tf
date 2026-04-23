# modules/cluster-monitoring/variables.tf

variable "cluster_name" {
  description = "AKS cluster name (used as the basename in DCR / rule-group names and the `clusterName` property inside each rule group)."
  type        = string
  nullable    = false
}

variable "aks_cluster_id" {
  description = "Full ARM id of the AKS managed cluster. DCRA parent and a scope entry on the UX rule group."
  type        = string
  nullable    = false
}

variable "location" {
  description = "Azure region for the DCR + rule-group resources. Must match the AMW's region for the DCRA to succeed."
  type        = string
  nullable    = false
}

variable "parent_id" {
  description = "Resource group ARM id under which the DCR + rule-group resources are created. Typically the cluster's resource group."
  type        = string
  nullable    = false
}

variable "dce_id" {
  description = "Full ARM id of the env-scope Data Collection Endpoint (owned by `bootstrap/environment`). The DCR references this as `dataCollectionEndpointId` so Prometheus ingestion transits the env NSP."
  type        = string
  nullable    = false
}

variable "amw_id" {
  description = "Full ARM id of the env-scope Azure Monitor Workspace. DCR destination; rule-group scope; also the Monitoring Metrics Publisher role-assignment scope (assigned by the caller)."
  type        = string
  nullable    = false
}

variable "tags" {
  description = "Tags applied to every resource in this module."
  type        = map(string)
  default     = {}
  nullable    = false
}
