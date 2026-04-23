# modules/cluster-kv/main.tf
#
# Per-cluster Key Vault. PLAN §4 Stage 1:
#   - RBAC-authorized (no access policies)
#   - Standard SKU
#   - Purge protection ON
#   - publicNetworkAccess Disabled → all ingestion via private endpoint
#     (PE attached by Stage 1 to the env-region `snet-pe-env`; authored
#     in a separate resource so the module can stay PE-agnostic for
#     future mgmt-only KVs that peer through `snet-pe-fleet`).
#
# Role assignments (ESO, external-dns, team UAMIs) are intentionally
# authored by the caller (Stage 1 `main.rbac.tf`), not here — the
# module is scope-agnostic so it can be reused from Stage 0 if a
# second fleet-local KV is ever introduced.

resource "azapi_resource" "kv" {
  type      = "Microsoft.KeyVault/vaults@2023-07-01"
  name      = var.name
  parent_id = var.parent_id
  location  = var.location

  body = {
    properties = {
      tenantId = var.tenant_id
      sku = {
        family = "A"
        name   = "standard"
      }
      enableRbacAuthorization = true
      enablePurgeProtection   = true
      # 7-day soft-delete retention — minimum allowed. Operators
      # dealing with a compromised secret want rotation + purge to
      # complete on a weekly cadence, not a 90-day one.
      softDeleteRetentionInDays = 7
      publicNetworkAccess       = "disabled"
      networkAcls = {
        defaultAction = "Deny"
        bypass        = "AzureServices"
      }
    }
  }

  response_export_values = ["id", "properties.vaultUri"]

  tags = var.tags
}
