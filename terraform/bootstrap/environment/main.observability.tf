# main.observability.tf
#
# Per-env observability stack: NSP + AMW + DCE + Grafana + PE + Action Group.
# All resources scoped to local.environment.subscription_id (the env's sub).
#
# NSP is still in preview in several regions — verify availability before
# apply. Fallback = AMPLS; see PLAN §15.
#
# TODO(phase3-wire-receivers): the action-group receivers wire KV secret
# *names* but the receiver blocks below need the actual secret values read
# via `azapi_resource_action` (ephemeral list) once fleet KV is populated.
# For Phase 1 the values default to placeholder strings.

locals {
  amw_name     = "amw-${local.fleet.name}-${var.env}"
  dce_name     = "dce-${local.fleet.name}-${var.env}"
  amg_name     = "amg-${local.fleet.name}-${var.env}"
  nsp_name     = "nsp-${local.fleet.name}-${var.env}"
  pe_name      = "pe-amg-${local.fleet.name}-${var.env}"
  ag_name      = "ag-${local.fleet.name}-${var.env}"
  ag_short     = substr("${local.observ.action_group.short_name_prefix}${var.env}", 0, 12)
  pdns_grafana = local.observ.network_isolation.grafana_private_dns_zone
}

# --- NSP ---------------------------------------------------------------------

resource "azapi_resource" "nsp" {
  type      = "Microsoft.Network/networkSecurityPerimeters@2023-08-01-preview"
  name      = local.nsp_name
  parent_id = azapi_resource.rg_env_obs.id
  location  = local.location

  body = {
    properties = {}
  }
  response_export_values = ["id"]
}

resource "azapi_resource" "nsp_profile" {
  type      = "Microsoft.Network/networkSecurityPerimeters/profiles@2023-08-01-preview"
  name      = local.observ.network_isolation.nsp_profile_name
  parent_id = azapi_resource.nsp.id

  body = {
    properties = {}
  }
}

resource "azapi_resource" "nsp_rule_cluster_ingestion" {
  type      = "Microsoft.Network/networkSecurityPerimeters/profiles/accessRules@2023-08-01-preview"
  name      = "allow-cluster-ingestion"
  parent_id = azapi_resource.nsp_profile.id

  body = {
    properties = {
      direction     = "Inbound"
      subscriptions = [{ id = "/subscriptions/${local.env_sub_id}" }]
    }
  }
}

resource "azapi_resource" "nsp_rule_grafana_query" {
  type      = "Microsoft.Network/networkSecurityPerimeters/profiles/accessRules@2023-08-01-preview"
  name      = "allow-grafana-query"
  parent_id = azapi_resource.nsp_profile.id

  body = {
    properties = {
      direction     = "Inbound"
      subscriptions = [{ id = "/subscriptions/${local.env_sub_id}" }]
    }
  }
}

# --- AMW ---------------------------------------------------------------------

resource "azapi_resource" "amw" {
  type      = "Microsoft.Monitor/accounts@2023-04-03"
  name      = local.amw_name
  parent_id = azapi_resource.rg_env_obs.id
  location  = local.location

  body = {
    properties = {
      publicNetworkAccess = local.observ.monitor_workspace.public_network_access
    }
  }
  response_export_values = ["id", "properties.metrics.prometheusQueryEndpoint"]
}

resource "azapi_resource" "amw_nsp_assoc" {
  type      = "Microsoft.Network/networkSecurityPerimeters/resourceAssociations@2023-08-01-preview"
  name      = "amw-${var.env}"
  parent_id = azapi_resource.nsp.id

  body = {
    properties = {
      privateLinkResource = { id = azapi_resource.amw.id }
      profile             = { id = azapi_resource.nsp_profile.id }
      accessMode          = "Enforced"
    }
  }
}

# --- DCE ---------------------------------------------------------------------

resource "azapi_resource" "dce" {
  type      = "Microsoft.Insights/dataCollectionEndpoints@2023-03-11"
  name      = local.dce_name
  parent_id = azapi_resource.rg_env_obs.id
  location  = local.location

  body = {
    kind = "Linux"
    properties = {
      networkAcls = {
        publicNetworkAccess = local.observ.data_collection_endpoint.public_network_access
      }
    }
  }
  response_export_values = [
    "id",
    "properties.logsIngestion.endpoint",
    "properties.metricsIngestion.endpoint",
  ]
}

resource "azapi_resource" "dce_nsp_assoc" {
  type      = "Microsoft.Network/networkSecurityPerimeters/resourceAssociations@2023-08-01-preview"
  name      = "dce-${var.env}"
  parent_id = azapi_resource.nsp.id

  body = {
    properties = {
      privateLinkResource = { id = azapi_resource.dce.id }
      profile             = { id = azapi_resource.nsp_profile.id }
      accessMode          = "Enforced"
    }
  }
}

# --- Grafana -----------------------------------------------------------------

resource "azapi_resource" "amg" {
  type      = "Microsoft.Dashboard/grafana@2023-09-01"
  name      = local.amg_name
  parent_id = azapi_resource.rg_env_obs.id
  location  = local.location

  identity {
    type = "SystemAssigned"
  }

  body = {
    sku = { name = "Standard" }
    properties = {
      apiKey                  = "Disabled"
      publicNetworkAccess     = "Disabled"
      deterministicOutboundIP = "Enabled"
      zoneRedundancy          = "Enabled"
      grafanaMajorVersion     = "10"
      # AMW integration is an inline property of the grafana resource, not a
      # child resource type. Confirmed via azureschema against
      # Microsoft.Dashboard/grafana @ 2023-09-01.
      grafanaIntegrations = {
        azureMonitorWorkspaceIntegrations = [
          { azureMonitorWorkspaceResourceId = azapi_resource.amw.id },
        ]
      }
    }
  }
  response_export_values = ["id", "identity.principalId", "properties.endpoint"]
}

# Grafana PE + PDNS
resource "azapi_resource" "amg_pe" {
  type      = "Microsoft.Network/privateEndpoints@2023-11-01"
  name      = local.pe_name
  parent_id = azapi_resource.rg_env_obs.id
  location  = local.location

  body = {
    properties = {
      subnet = { id = local.environment.networking.grafana_pe_subnet_id }
      privateLinkServiceConnections = [{
        name = "amg"
        properties = {
          privateLinkServiceId = azapi_resource.amg.id
          groupIds             = ["grafana"]
        }
      }]
    }
  }
  response_export_values = ["id"]
}

resource "azapi_resource" "pdns_grafana" {
  type      = "Microsoft.Network/privateDnsZones@2020-06-01"
  name      = local.pdns_grafana
  parent_id = azapi_resource.rg_env_obs.id
  location  = "global"

  body = { properties = {} }
}

resource "azapi_resource" "pdns_grafana_links" {
  for_each = toset(local.environment.networking.grafana_pe_linked_vnet_ids)

  type      = "Microsoft.Network/privateDnsZones/virtualNetworkLinks@2020-06-01"
  name      = "link-${basename(each.value)}"
  parent_id = azapi_resource.pdns_grafana.id
  location  = "global"

  body = {
    properties = {
      registrationEnabled = false
      virtualNetwork      = { id = each.value }
    }
  }
}

resource "azapi_resource" "amg_pe_dns_zone_group" {
  type      = "Microsoft.Network/privateEndpoints/privateDnsZoneGroups@2023-11-01"
  name      = "default"
  parent_id = azapi_resource.amg_pe.id

  body = {
    properties = {
      privateDnsZoneConfigs = [{
        name = "grafana"
        properties = {
          privateDnsZoneId = azapi_resource.pdns_grafana.id
        }
      }]
    }
  }
}

# --- Grafana role assignments -----------------------------------------------

locals {
  role_monitoring_reader      = "43d0d8ad-25c7-4714-9337-8ba259a9fe05"
  role_monitoring_data_reader = "b0d8363b-8ddd-447d-831f-62ca05bff136"
  role_grafana_admin          = "22926164-76b3-42b3-bc55-97df8dab3e41"
  role_grafana_editor         = "a79a5197-3a5c-4973-a920-486035ffd60f"
}

resource "azapi_resource" "ra_amg_monitoring_reader" {
  type      = "Microsoft.Authorization/roleAssignments@2022-04-01"
  name      = uuidv5("url", "amg-mon-reader-${local.env_sub_id}")
  parent_id = "/subscriptions/${local.env_sub_id}"

  body = {
    properties = {
      roleDefinitionId = "/subscriptions/${local.env_sub_id}/providers/Microsoft.Authorization/roleDefinitions/${local.role_monitoring_reader}"
      principalId      = azapi_resource.amg.output.identity.principalId
      principalType    = "ServicePrincipal"
    }
  }
}

resource "azapi_resource" "ra_amg_amw_data_reader" {
  type      = "Microsoft.Authorization/roleAssignments@2022-04-01"
  name      = uuidv5("url", "amg-amw-reader-${azapi_resource.amw.id}")
  parent_id = azapi_resource.amw.id

  body = {
    properties = {
      roleDefinitionId = "/subscriptions/${local.env_sub_id}/providers/Microsoft.Authorization/roleDefinitions/${local.role_monitoring_data_reader}"
      principalId      = azapi_resource.amg.output.identity.principalId
      principalType    = "ServicePrincipal"
    }
  }
}

resource "azapi_resource" "ra_amg_group_admin" {
  for_each  = toset(local.environment.grafana.admins)
  type      = "Microsoft.Authorization/roleAssignments@2022-04-01"
  name      = uuidv5("url", "amg-admin-${each.value}-${azapi_resource.amg.id}")
  parent_id = azapi_resource.amg.id

  body = {
    properties = {
      roleDefinitionId = "/subscriptions/${local.env_sub_id}/providers/Microsoft.Authorization/roleDefinitions/${local.role_grafana_admin}"
      principalId      = each.value
      principalType    = "Group"
    }
  }
}

resource "azapi_resource" "ra_amg_group_editor" {
  for_each  = toset(local.environment.grafana.editors)
  type      = "Microsoft.Authorization/roleAssignments@2022-04-01"
  name      = uuidv5("url", "amg-editor-${each.value}-${azapi_resource.amg.id}")
  parent_id = azapi_resource.amg.id

  body = {
    properties = {
      roleDefinitionId = "/subscriptions/${local.env_sub_id}/providers/Microsoft.Authorization/roleDefinitions/${local.role_grafana_editor}"
      principalId      = each.value
      principalType    = "Group"
    }
  }
}

# --- Action Group ------------------------------------------------------------
#
# Placeholder receivers — receiver-secret wiring lands in Phase 3.
# Group short name capped at 12 chars; see ARM docs.

resource "azapi_resource" "ag" {
  type      = "Microsoft.Insights/actionGroups@2023-01-01"
  name      = local.ag_name
  parent_id = azapi_resource.rg_env_obs.id
  location  = "global"

  body = {
    properties = {
      enabled               = true
      groupShortName        = local.ag_short
      webhookReceivers      = []
      emailReceivers        = []
      smsReceivers          = []
      armRoleReceivers      = []
      azureAppPushReceivers = []
      itsmReceivers         = []
    }
  }
  response_export_values = ["id"]
}
